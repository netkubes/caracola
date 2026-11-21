defmodule Caracola.Call do
  @moduledoc """
  Call process: every request, response and transaction with the same
  Call-ID is handled by a single process, which serializes all the work for
  that call. Equivalent to NkSIP's `nksip_call_srv` and `nksip_router`.

  Call processes are started on demand, registered in a `Registry` of the
  service (which also enforces `max_calls`) and stop when they have no
  transactions or dialogs left. User callbacks run inside the call process and receive this
  struct as the `call` argument.

  A process may stop right after a caller found it; in that case the work
  had not been received, and it is sent again to a new process.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Caracola.Call.{Auth, Dialog, Event, Timers, Trans, UAC, UAS}
  alias Caracola.{Message, Util}
  alias Caracola.Transport.Port

  @typedoc "The state of a call: all the transactions, forks and dialogs sharing a Call-ID, owned by one process per service and Call-ID."
  @type t :: %__MODULE__{
          service: module(),
          call_id: String.t(),
          config: keyword(),
          trans: %{pos_integer() => term()},
          dialogs: %{Caracola.Dialog.id() => Caracola.Dialog.t()},
          forks: %{pos_integer() => term()},
          auths: MapSet.t(),
          events: MapSet.t(),
          next: pos_integer(),
          msgs: %{String.t() => pos_integer()}
        }

  defstruct [
    :service,
    :call_id,
    config: [],
    trans: %{},
    dialogs: %{},
    forks: %{},
    auths: MapSet.new(),
    events: MapSet.new(),
    next: 1,
    msgs: %{},
    start_time: nil,
    hibernate: false
  ]

  @retries 5

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc false
  def registry(service), do: Module.concat(service, Sip.Calls)

  @doc false
  def supervisor(service), do: Module.concat(service, Sip.CallSup)

  @doc false
  # Children started by the Caracola plugin for each service. Calls are
  # spread among many supervisors, because the shutdown time of a
  # DynamicSupervisor grows with the square of its children (for each one,
  # it scans a mailbox filling up with the exits of the previous ones).
  def children(service) do
    partitions = System.schedulers_online()

    [
      {Registry, keys: :unique, name: registry(service), partitions: partitions},
      {PartitionSupervisor,
       child_spec: {DynamicSupervisor, strategy: :one_for_one},
       name: supervisor(service),
       partitions: partitions * 8}
    ]
  end

  @doc """
  Sends a piece of work to the process of a call, starting it if needed.
  """
  @spec work(module(), String.t(), term(), timeout()) :: term()
  def work(service, call_id, work, timeout \\ :infinity),
    do: work(service, call_id, work, timeout, @retries)

  defp work(_service, _call_id, _work, _timeout, 0), do: {:error, :call_unavailable}

  defp work(service, call_id, work, timeout, retries) do
    with {:ok, pid} <- find_or_start(service, call_id) do
      try do
        GenServer.call(pid, {:work, work}, timeout)
      catch
        # The process stopped before receiving the work. It may still be in
        # the registry for a moment.
        :exit, {reason, _} when reason in [:noproc, :normal] ->
          Process.sleep(@retries - retries + 1)
          work(service, call_id, work, timeout, retries - 1)

        :exit, {reason, _} ->
          {:error, {:exit, reason}}
      end
    end
  end

  @doc false
  # Work for an existing call process (it is not started), or `default`
  def query(service, call_id, work, default) do
    case find(service, call_id) do
      nil -> default
      pid -> GenServer.call(pid, {:work, work})
    end
  catch
    :exit, _ -> default
  end

  @doc "Returns the pid of a call process, if started."
  @spec find(module(), String.t()) :: pid() | nil
  def find(service, call_id) do
    case Registry.lookup(registry(service), call_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Returns the number of calls of a service."
  @spec count(module()) :: non_neg_integer()
  def count(service), do: Registry.count(registry(service))

  defp find_or_start(service, call_id) do
    cond do
      Process.whereis(registry(service)) == nil ->
        {:error, :service_not_started}

      pid = find(service, call_id) ->
        {:ok, pid}

      count(service) >= max_calls(service) ->
        {:error, :too_many_calls}

      true ->
        case DynamicSupervisor.start_child(
               {:via, PartitionSupervisor, {supervisor(service), call_id}},
               {__MODULE__, {service, call_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          # Started by someone else at the same time
          :ignore -> find_or_start(service, call_id)
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    # The registry or its tables are still starting (or stopping)
    ArgumentError -> {:error, :service_not_started}
  catch
    :exit, {:noproc, _} -> {:error, :service_not_started}
  end

  defp max_calls(service), do: config(service)[:max_calls] || 100_000

  @doc false
  def config(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> Keyword.get(config, :sip, [])
      :unknown -> []
    end
  end

  @doc false
  # Transport handler (see Caracola.Transport.Handler)
  def handle_message(%Port{} = port, %Message{} = msg, service) do
    msg = %{msg | service: service, port: port, id: Util.uid()}

    case service.caracola_received_message(msg) do
      :ok -> incoming(msg)
      :drop -> :ok
      {:reply, sipreply} -> reply_stateless(msg, sipreply)
    end
  end

  defp incoming(%Message{service: service} = msg) do
    case work(service, msg.call_id, {:incoming, msg}, 5_000) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("could not process SIP message: #{inspect(error)}", call_id: msg.call_id)

        reply_stateless(msg, 503)
    end
  end

  defp reply_stateless(%Message{class: {:req, method}} = msg, sipreply) when method != :ack,
    do: UAS.reply_stateless(msg, sipreply)

  defp reply_stateless(_msg, _sipreply), do: :ok

  ## ===================================================================
  ## GenServer
  ## ===================================================================

  @doc false
  def start_link({service, call_id}), do: GenServer.start_link(__MODULE__, {service, call_id})

  @impl true
  def init({service, call_id}) do
    case Registry.register(registry(service), call_id, nil) do
      {:ok, _} ->
        Malla.put_service_id(service)
        Logger.metadata(service: service, call_id: call_id)
        start_time = Caracola.Telemetry.start(:call, %{service: service, call_id: call_id})
        config = config(service)
        schedule_check(config)

        {:ok,
         %__MODULE__{
           service: service,
           call_id: call_id,
           config: config,
           start_time: start_time
         }}

      {:error, {:already_registered, _}} ->
        :ignore
    end
  end

  @impl true
  def handle_call({:work, {:incoming, msg}}, _from, call) do
    # The sender (a transport process) does not wait for the processing
    {:reply, :ok, call, {:continue, {:incoming, msg}}}
  end

  def handle_call({:work, work}, from, call), do: next(do_work(work, from, call))

  @impl true
  def handle_continue({:incoming, %Message{class: {:req, _}} = req}, call),
    do: next(UAS.request(req, call))

  def handle_continue({:incoming, %Message{class: {:resp, _, _}} = resp}, call),
    do: next(UAC.response(resp, call))

  @impl true
  def handle_info({:timeout, ref, {:dialog, tag, id}}, call),
    do: next(Dialog.fired(tag, id, ref, call))

  def handle_info({:remove_prov_event, key}, call),
    do: next(Event.remove_prov_event(key, call))

  def handle_info({:timeout, ref, {class, tag, id}}, call),
    do: next(Timers.fired(class, tag, id, ref, call))

  def handle_info(:check_call, call) do
    schedule_check(call.config)
    next(check_call(call))
  end

  def handle_info(_msg, call), do: next(call)

  defp do_work({:send, method, uri, opts}, from, call),
    do: UAC.send_new(method, uri, opts, from, call)

  defp do_work({:send_dialog, dialog_id, method, opts}, from, call),
    do: UAC.send_dialog(dialog_id, method, opts, from, call)

  defp do_work({:get_dialog, dialog_id}, from, call) do
    case Dialog.find(dialog_id, call) do
      %Caracola.Dialog{} = dialog -> reply_to(from, {{:ok, dialog}, call})
      nil -> reply_to(from, {{:error, :unknown_dialog}, call})
    end
  end

  defp do_work(:list_dialogs, from, call),
    do: reply_to(from, {Enum.map(Map.values(call.dialogs), &Caracola.Dialog.handle/1), call})

  defp do_work({:authorized, dialog_id}, from, call),
    do: reply_to(from, {Auth.authorized(call, dialog_id), call})

  defp do_work({:clear_authorized, dialog_id}, from, call),
    do: reply_to(from, {:ok, Auth.clear(call, dialog_id)})

  defp do_work({:stop_dialog, dialog_id}, from, call) do
    case Dialog.find(dialog_id, call) do
      %Caracola.Dialog{} = dialog -> reply_to(from, {:ok, Dialog.stop(:forced, dialog, call)})
      nil -> reply_to(from, {{:error, :unknown_dialog}, call})
    end
  end

  defp do_work({:reply, msg_id, sipreply}, from, call),
    do: reply_to(from, UAS.reply_id(msg_id, sipreply, call))

  defp do_work({:route, msg_id, route}, from, call),
    do: reply_to(from, UAS.route_id(msg_id, route, call))

  defp do_work({:cancel, msg_id, opts}, from, call),
    do: reply_to(from, UAC.cancel_id(msg_id, opts, call))

  defp do_work(:info, from, call) do
    GenServer.reply(from, for({id, t} <- call.trans, do: {id, t.class, t.method, t.status}))
    call
  end

  defp reply_to(from, {reply, call}) do
    GenServer.reply(from, reply)
    call
  end

  # Stops when there are no transactions, dialogs or forks left and no
  # pending messages
  ## ===================================================================
  ## Expiration
  ## ===================================================================

  # Every 2 * trans_timeout seconds, the call removes what should have
  # ended (as NkSIP's nksip_call:check_call/1). It is a safety net: timers
  # end transactions and dialogs well before.
  defp schedule_check(config),
    do: Process.send_after(self(), :check_call, 2_000 * (config[:trans_timeout] || 900))

  @doc false
  # Removes the transactions older than 2 * trans_timeout (replying
  # `{:error, :timeout}` to their callers), the forks of removed
  # transactions, and the dialogs without activity for 2 * dialog_timeout.
  # `shift` (seconds) moves the clock forward, for tests.
  def check_call(%__MODULE__{config: config} = call, shift \\ 0) do
    now = System.monotonic_time() + System.convert_time_unit(shift, :second, :native)
    max_trans = System.convert_time_unit(2 * (config[:trans_timeout] || 900), :second, :native)
    max_dialog = 2 * (config[:dialog_timeout] || 1800)

    {expired, trans} =
      Map.split_with(call.trans, fn {_id, t} ->
        is_integer(t.start_time) and now - t.start_time > max_trans
      end)

    for {id, t} <- expired do
      Logger.error("removing expired #{t.class} transaction #{id} (#{t.method})")
      Timers.cancel_all(t)

      if t.class == :uac and match?({pid, _} when is_pid(pid), t.from) and :async not in t.opts,
        do: GenServer.reply(t.from, {:error, :timeout})
    end

    forks = Map.filter(call.forks, fn {id, _fork} -> Map.has_key?(trans, id) end)
    call = %{call | trans: trans, forks: forks}
    os_now = System.os_time(:second) + shift

    call.dialogs
    |> Map.values()
    |> Enum.filter(&(os_now - &1.updated > max_dialog))
    |> Enum.reduce(call, fn dialog, call ->
      Logger.error("removing expired dialog #{dialog.id}")
      Dialog.stop(:timeout, dialog, call)
    end)
  end

  defp next(%__MODULE__{trans: trans, dialogs: dialogs, forks: forks} = call)
       when map_size(trans) == 0 and map_size(dialogs) == 0 and map_size(forks) == 0 do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, 0} ->
        meta = %{service: call.service, call_id: call.call_id}
        Caracola.Telemetry.stop(:call, call.start_time, meta)
        {:stop, :normal, call}

      _ ->
        {:noreply, call}
    end
  end

  # Calls whose transactions only wait for their timers (as the 32 seconds
  # of a non-INVITE transaction over UDP) hibernate, compacting their memory
  defp next(%__MODULE__{hibernate: true} = call),
    do: {:noreply, %{call | hibernate: false}, :hibernate}

  defp next(call), do: {:noreply, call}

  ## ===================================================================
  ## Transactions
  ## ===================================================================

  @doc false
  # Stores a transaction, or removes it if finished
  def update(%__MODULE__{} = call, %Trans{status: :finished} = trans) do
    trans |> Timers.cancel_all()
    %{call | trans: Map.delete(call.trans, trans.id), hibernate: true}
  end

  def update(%__MODULE__{} = call, %Trans{status: status} = trans) do
    # As NkSIP, the call hibernates when a transaction reaches a state that
    # only waits for timers or retransmissions
    hibernate =
      call.hibernate or status in [:invite_accepted, :completed] or
        (status == :invite_completed and trans.class == :uac)

    %{call | trans: Map.put(call.trans, trans.id, trans), hibernate: hibernate}
  end

  @doc false
  # Telemetry event of the first final response of a transaction
  def telemetry(class, %Trans{start_time: start_time} = trans, code, call)
      when is_integer(start_time) do
    meta = %{service: call.service, call_id: call.call_id, method: trans.method, code: code}
    Caracola.Telemetry.stop(class, start_time, meta)
  end

  def telemetry(_class, _trans, _code, _call), do: :ok

  @doc false
  def new_trans_id(%__MODULE__{next: next} = call), do: {next, %{call | next: next + 1}}

  @doc false
  def find_trans(%__MODULE__{trans: trans}, class, trans_id) do
    Enum.find_value(trans, fn {_id, t} ->
      if t.class == class and t.trans_id == trans_id, do: t
    end)
  end

  @doc false
  def put_msg(%__MODULE__{} = call, %Message{id: id}, trans_id) when is_binary(id),
    do: %{call | msgs: Map.put(call.msgs, id, trans_id)}

  def put_msg(call, _msg, _trans_id), do: call

  @doc false
  # The messages of a transaction now belong to another one (the request
  # was sent again, as after an authentication challenge), so that the
  # handle returned to the caller still finds it
  def move_msgs(%__MODULE__{msgs: msgs} = call, from_id, to_id) do
    msgs = Map.new(msgs, fn {msg_id, id} -> {msg_id, if(id == from_id, do: to_id, else: id)} end)
    %{call | msgs: msgs}
  end

  @doc false
  def trans_by_msg(%__MODULE__{} = call, msg_id) do
    with {:ok, trans_id} <- Map.fetch(call.msgs, msg_id), do: Map.fetch(call.trans, trans_id)
  end

  @doc false
  # Replies to a caller, if any (requests generated by the call itself have none)
  def reply(nil, _reply), do: :ok
  def reply(from, reply), do: GenServer.reply(from, reply)

  @doc false
  # Calls a user callback, returning `{:error, exception}` if it fails
  def callback(%__MODULE__{service: service}, fun, args) do
    case service.caracola_callback(fun, args) do
      {:done, result} -> result
      _ -> apply(service, fun, args)
    end
  rescue
    error ->
      Logger.error("error calling #{fun}: " <> Exception.format(:error, error, __STACKTRACE__))
      {:error, error}
  end
end
