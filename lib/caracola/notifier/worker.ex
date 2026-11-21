defmodule Caracola.Notifier.Worker do
  @moduledoc false
  # Sends the NOTIFYs of Caracola.Notifier. Workers are partitioned by
  # resource, so the NOTIFYs of a resource are sent by the same process, in
  # order: the state is read and the version taken just before each NOTIFY
  # is queued (with :async) in the process of its call.

  use GenServer

  require Logger

  alias Caracola.Notifier.Store
  alias Caracola.UAC

  @partitions Caracola.Notifier.Workers

  def child_spec(_) do
    %{
      id: @partitions,
      start:
        {PartitionSupervisor, :start_link,
         [
           [
             child_spec: %{id: __MODULE__, start: {__MODULE__, :start_link, []}},
             name: @partitions
           ]
         ]},
      type: :supervisor
    }
  end

  def start_link, do: GenServer.start_link(__MODULE__, nil)

  # Sends the state to some watchers of a resource, or to all of them, and
  # then calls then_fun
  def notify(service, event, aor, handles, then_fun) do
    worker = {:via, PartitionSupervisor, {@partitions, {service, event, aor}}}
    GenServer.cast(worker, {:notify, service, event, aor, handles, then_fun})
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_cast({:notify, service, event, aor, handles, then_fun}, state) do
    handles = if handles == :all, do: Store.watchers(service, event, aor), else: handles
    Enum.each(handles, &send_notify(&1, service, event, aor))
    if then_fun, do: run(then_fun)
    {:noreply, state}
  end

  defp run(fun) do
    fun.()
  catch
    kind, reason -> Logger.warning("notifier function failed: " <> Exception.format(kind, reason))
  end

  defp send_notify(handle, service, event, aor) do
    with version when is_integer(version) <- Store.next_version(handle) do
      opts =
        case Store.status(handle) do
          :active -> body(service, event, aor, version)
          :pending -> [subscription_state: :pending]
          {:terminated, reason} -> [subscription_state: {:terminated, reason}]
          nil -> []
        end

      case UAC.notify(handle, [:async, timeout: 5000] ++ opts) do
        {:async, _} -> :ok
        {:error, _} -> Caracola.Notifier.removed(handle)
      end
    end
  catch
    kind, reason ->
      Logger.warning("could not send NOTIFY: " <> Exception.format(kind, reason))
  end

  defp body(service, event, aor, version) do
    case service.sip_notifier_body(event, aor, version, service) do
      {content_type, body} -> [content_type: content_type, body: body]
      _ -> []
    end
  end
end
