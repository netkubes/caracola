defmodule Caracola.UACAutoRegister.Server do
  @moduledoc false
  # Process of the automatic registrations and pings of a service. Every
  # `timer` seconds it sends the ones whose time has come, from other
  # processes, and gets their results.
  #
  # Registrations started by Caracola.UACAutoOutbound (RFC 5626 §4.2) have
  # a reg-id, and their flow is kept alive with a
  # Caracola.Transport.Keepalive process. If it fails, or the registration
  # fails, they are sent again after an exponential backoff (§4.5).

  use GenServer

  require Logger

  alias Caracola.Transport.{Keepalive, Port}
  alias Caracola.{UAC, Util}

  @default_interval 300

  def child_spec({service, _timer, _ob_config} = args),
    do: %{id: {__MODULE__, service}, start: {__MODULE__, :start_link, [args]}}

  def start_link({service, _timer, _ob_config} = args),
    do: GenServer.start_link(__MODULE__, args, name: name(service))

  def call(service, msg, timeout \\ 5000) do
    GenServer.call(name(service), msg, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :service_not_started}
  end

  defp name(service), do: Module.concat(service, Sip.UACAutoRegister)

  ## ===================================================================
  ## GenServer
  ## ===================================================================

  @impl true
  def init({service, timer, ob_config}) do
    # To unregister on stop, and to know when keepalives fail
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :check, timer * 1000)

    {:ok,
     %{service: service, timer: timer, ob_config: ob_config, reg: %{}, ping: %{}, next_reg_id: 1}}
  end

  @impl true
  def handle_call({:start, class, id, uri, opts}, from, state) do
    # opts mixes flags and {key, value} pairs
    expires = Util.opt(opts, :expires, @default_interval)
    outbound? = :auto_outbound in opts and state.ob_config != nil
    {reg_id, state} = reg_id(outbound?, Util.opt(opts, :reg_id), state)

    opts =
      Enum.reject(
        opts,
        &(match?({key, _} when key in [:expires, :reg_id], &1) or &1 == :auto_outbound)
      )

    item = %{
      id: id,
      uri: uri,
      opts: opts,
      call_id: Util.opt(opts, :call_id) || Util.uid(),
      interval: expires,
      from: from,
      cseq: :rand.uniform(1_000_000),
      next: now(),
      ok: nil,
      service_route: [],
      ob: if(outbound?, do: %{reg_id: reg_id, fails: 0, keepalive: nil})
    }

    state = stop_keepalive(get_in(state, [class, id]), state)
    state = put_in(state, [class, id], item)
    {:noreply, check(state)}
  end

  def handle_call({:stop, class, id}, _from, state) do
    case Map.pop(Map.fetch!(state, class), id) do
      {nil, _} ->
        {:reply, :not_found, state}

      {item, items} ->
        stop_keepalive(item, state)
        if class == :reg, do: unregister_async(item, state.service)
        {:reply, :ok, Map.put(state, class, items)}
    end
  end

  def handle_call({:get, class}, _from, state) do
    now = now()
    items = for {id, item} <- Map.fetch!(state, class), do: {id, item.ok, next(item, now)}
    {:reply, items, state}
  end

  def handle_call({:service_route, id}, _from, state) do
    case state.reg do
      %{^id => item} -> {:reply, item.service_route, state}
      _ -> {:reply, [], state}
    end
  end

  def handle_call(:get_outbound, _from, state) do
    now = now()

    items =
      for {id, %{ob: %{} = ob} = item} <- state.reg,
          do: {id, item.ok, next(item, now), ob.fails}

    {:reply, items, state}
  end

  def handle_call(:get_keepalives, _from, state) do
    items =
      for {id, %{ob: %{keepalive: pid}}} <- state.reg, is_pid(pid), do: {id, pid}

    {:reply, items, state}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, state.timer * 1000)
    {:noreply, check(state)}
  end

  def handle_info({:result, class, id, code, meta}, state) do
    case get_in(state, [class, id]) do
      nil ->
        {:noreply, state}

      item ->
        item = result(class, item, code, meta, state)
        {:noreply, put_in(state, [class, id], item)}
    end
  end

  # The flow is alive
  def handle_info({:keepalive_ok, pid}, state) do
    case find_keepalive(pid, state) do
      nil -> {:noreply, state}
      item -> {:noreply, put_in(state, [:reg, item.id, :ob, :fails], 0)}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case find_keepalive(pid, state) do
      nil ->
        if reason != :normal,
          do: Logger.warning("automatic registration process failed: #{inspect(reason)}")

        {:noreply, state}

      # The flow failed: registered again after the backoff
      item ->
        Logger.notice("outbound flow of registration #{inspect(item.id)} failed")
        item = put_in(item.ob.keepalive, nil)
        item = result(:reg, item, 503, [cseq_num: item.cseq - 1], state)
        {:noreply, put_in(state, [:reg, item.id], item)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    for {_id, %{ok: true} = item} <- state.reg do
      stop_keepalive(item, state)
      unregister(item, state.service)
    end
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp now, do: System.monotonic_time(:second)

  defp next(%{next: next}, now) when is_integer(next), do: next - now
  defp next(_item, _now), do: 0

  # reg-id of an outbound registration: the requested one, or the next free
  defp reg_id(false, _reg_id, state), do: {nil, state}

  defp reg_id(true, reg_id, state) when is_integer(reg_id) and reg_id > 0,
    do: {reg_id, %{state | next_reg_id: max(state.next_reg_id, reg_id + 1)}}

  defp reg_id(true, _reg_id, state),
    do: {state.next_reg_id, %{state | next_reg_id: state.next_reg_id + 1}}

  # Sends the registrations and pings whose time has come
  defp check(state) do
    now = now()

    Enum.reduce([:reg, :ping], state, fn class, state ->
      items = Map.new(Map.fetch!(state, class), &check_item(&1, class, now, state.service))
      Map.put(state, class, items)
    end)
  end

  defp check_item({id, item}, class, now, service) do
    if is_integer(item.next) and item.next <= now,
      do: {id, send_item(class, item, service)},
      else: {id, item}
  end

  defp send_item(class, item, service) do
    self = self()
    meta = [:cseq_num, "retry-after", "service-route"]

    {extra, meta} =
      case item.ob do
        %{reg_id: reg_id} -> {[reg_id: reg_id], meta ++ ["require", "flow-timer", :port]}
        nil -> {[], meta}
      end

    opts = [call_id: item.call_id, cseq_num: item.cseq, get_meta: meta] ++ extra ++ item.opts

    spawn_link(fn ->
      result =
        case class do
          :reg -> UAC.register(service, item.uri, [:contact, expires: item.interval] ++ opts)
          :ping -> UAC.options(service, item.uri, opts)
        end

      {code, meta} =
        case result do
          {:ok, code, meta} -> {code, meta}
          _ -> {500, [cseq_num: item.cseq]}
        end

      send(self, {:result, class, item.id, code, meta})
    end)

    %{item | next: nil}
  end

  defp result(class, item, code, meta, state) do
    if item.from, do: GenServer.reply(item.from, {:ok, code < 300})
    ok = code < 300

    if ok != item.ok do
      fun =
        if class == :reg,
          do: :sip_uac_auto_register_updated_reg,
          else: :sip_uac_auto_register_updated_ping

      callback(state.service, fun, [item.id, ok, state.service])
    end

    {item, time} = outbound(item, code, meta, state)

    %{
      item
      | ok: ok,
        from: nil,
        service_route: service_route(class, code, meta, item),
        cseq: (Util.opt(meta, :cseq_num) || item.cseq) + 1,
        next: now() + (time || time(class, item, code, meta))
    }
  end

  defp service_route(:reg, code, meta, _item) when code in 200..299,
    do: Util.opt(meta, "service-route") || []

  defp service_route(_class, _code, _meta, item), do: item.service_route

  # Registrations are refreshed before they expire (5 seconds or 10%
  # before). After a 503, the Retry-After is used.
  defp time(class, item, code, meta) do
    retry =
      with 503 <- code,
           [value | _] <- Util.opt(meta, "retry-after") || [],
           {secs, _} <- Integer.parse(value) do
        secs
      else
        _ -> nil
      end

    cond do
      retry -> retry
      class == :reg and code < 300 -> max(1, min(div(item.interval * 9, 10), item.interval - 5))
      true -> item.interval
    end
  end

  # Outbound registrations: the flow of a successful one is kept alive (if
  # the registrar supports outbound); failed ones are sent again after
  # the backoff of RFC 5626 §4.5
  defp outbound(%{ob: nil} = item, _code, _meta, _state), do: {item, nil}

  defp outbound(%{ob: ob} = item, code, meta, state) when code < 300 do
    stop_keepalive(item, state)

    keepalive =
      with ["outbound" | _] <- (Util.opt(meta, "require") || []) |> Enum.flat_map(&words/1),
           %Port{remote_ip: ip} = port when ip != nil <- Util.opt(meta, :port),
           {:ok, pid} <- Keepalive.start_link(port, keepalive_secs(port, meta, state), self()) do
        pid
      else
        _ -> nil
      end

    {%{item | ob: %{ob | keepalive: keepalive}}, nil}
  end

  defp outbound(%{ob: ob} = item, _code, _meta, state) do
    stop_keepalive(item, state)
    config = state.ob_config

    # All the outbound registrations are failing
    base =
      if Enum.any?(state.reg, fn {id, reg} -> (id != item.id and reg.ob) && reg.ob.fails == 0 end),
         do: config[:any_ok],
         else: config[:all_fail]

    upper = min(config[:max_time], base * Integer.pow(2, ob.fails + 1))
    time = max(1, round(upper * Enum.random(50..100) / 100))
    {%{item | ob: %{ob | keepalive: nil, fails: ob.fails + 1}}, time}
  end

  defp words(value), do: value |> String.split(",") |> Enum.map(&String.trim/1)

  # The Flow-Timer of the registrar, or the default of the transport, minus
  # up to 20% (RFC 5626 §4.4.1)
  defp keepalive_secs(%Port{transport: transport}, meta, state) do
    secs =
      with [value | _] <- Util.opt(meta, "flow-timer") || [],
           {secs, _} when secs > 5 <- Integer.parse(value) do
        secs
      else
        _ when transport == :udp -> state.ob_config[:udp_ttl]
        _ -> state.ob_config[:tcp_ttl]
      end

    max(1, div(secs * Enum.random(80..100), 100))
  end

  defp stop_keepalive(%{ob: %{keepalive: pid}}, state) when is_pid(pid) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    state
  end

  defp stop_keepalive(_item, state), do: state

  defp find_keepalive(pid, state) do
    Enum.find_value(state.reg, fn
      {_id, %{ob: %{keepalive: ^pid}} = item} -> item
      _ -> nil
    end)
  end

  defp unregister_async(item, service), do: spawn(fn -> unregister(item, service) end)

  defp unregister(item, service) do
    reg_id = if item.ob, do: [reg_id: item.ob.reg_id], else: []
    opts = [:contact, call_id: item.call_id, cseq_num: item.cseq, expires: 0, timeout: 5000]
    UAC.register(service, item.uri, opts ++ reg_id ++ item.opts)
  end

  defp callback(service, fun, args) do
    apply(service, fun, args)
  rescue
    error -> Logger.error("error calling #{fun}: " <> Exception.message(error))
  end
end
