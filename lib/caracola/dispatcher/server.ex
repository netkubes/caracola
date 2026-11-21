defmodule Caracola.Dispatcher.Server do
  @moduledoc false
  # Health checks of the destinations of Caracola.Dispatcher. The status of
  # each destination ({{:status, key}, status, failures}) and the
  # round-robin counter of each group ({{:next, group}, n}) are kept in a
  # public ETS table of the service, owned by this process. Every probe
  # interval it sends an OPTIONS to each destination, from other
  # processes, and gets their results.

  use GenServer

  require Logger

  alias Caracola.UAC

  def child_spec({service, _keys, _probe} = args),
    do: %{id: {__MODULE__, service}, start: {__MODULE__, :start_link, [args]}}

  def start_link({service, _keys, _probe} = args),
    do: GenServer.start_link(__MODULE__, args, name: table(service))

  def status(service, key) do
    case :ets.lookup(table(service), {:status, key}) do
      [{_, status, _}] -> status
      [] -> :up
    end
  rescue
    ArgumentError -> :up
  end

  def next(service, group) do
    :ets.update_counter(table(service), {:next, group}, 1, {{:next, group}, -1})
  rescue
    ArgumentError -> 0
  end

  def set_status(service, key, status) do
    GenServer.call(table(service), {:set_status, key, status})
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp table(service), do: Module.concat(service, Sip.Dispatcher)

  ## ===================================================================
  ## GenServer
  ## ===================================================================

  @impl true
  def init({service, keys, probe}) do
    table = :ets.new(table(service), [:named_table, :public, :set, read_concurrency: true])
    for key <- keys, do: :ets.insert(table, {{:status, key}, :up, 0})
    if probe, do: send(self(), :probe)
    {:ok, %{service: service, table: table, keys: keys, probe: probe}}
  end

  @impl true
  def handle_call({:set_status, key, status}, _from, state) do
    update(key, status, 0, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:probe, %{service: service, probe: probe} = state) do
    Process.send_after(self(), :probe, probe[:interval])
    server = self()

    for key <- state.keys do
      spawn(fn -> send(server, {:probe_result, key, probe(service, key, probe[:timeout])}) end)
    end

    {:noreply, state}
  end

  def handle_info({:probe_result, key, ok?}, state) do
    case :ets.lookup(state.table, {:status, key}) do
      [{_, _, _}] when ok? ->
        update(key, :up, 0, state)

      [{_, status, failures}] ->
        failures = failures + 1
        status = if failures >= state.probe[:failures], do: :down, else: status
        update(key, status, failures, state)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp probe(service, key, timeout) do
    case UAC.options(service, key, timeout: timeout) do
      {:ok, code, _} -> code not in [408, 503]
      _ -> false
    end
  catch
    _, _ -> false
  end

  defp update(key, status, failures, %{table: table, service: service}) do
    case :ets.lookup(table, {:status, key}) do
      [{_, ^status, _}] ->
        :ok

      _ ->
        Logger.notice("dispatcher destination #{key} is #{status}", service: service)

        :telemetry.execute([:caracola, :dispatcher, :status], %{}, %{
          service: service,
          uri: key,
          status: status
        })
    end

    :ets.insert(table, {{:status, key}, status, failures})
  end
end
