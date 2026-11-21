defmodule Caracola.B2BUA.Bridge do
  @moduledoc false
  # Process of a bridge (see Caracola.B2BUA). It is registered with the
  # Call-IDs of both legs, so the plugin callbacks of either leg find it.
  # Responses to the requests it sends come back as {:uac, tag, reply}
  # messages, from the callbacks of the async requests.

  use GenServer, restart: :temporary

  require Logger

  alias Caracola.{B2BUA, Dialog, Message, SDP, Tokens, UAC, Util}

  @registry Caracola.B2BUA.Registry

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  ## ===================================================================
  ## GenServer
  ## ===================================================================

  @impl true
  def init({%Message{service: service, call_id: a_call_id} = req, uri, opts}) do
    b_call_id = Util.uid()
    {:ok, _} = Registry.register(@registry, {service, a_call_id}, nil)
    {:ok, _} = Registry.register(@registry, {service, b_call_id}, nil)

    bridge = %B2BUA{
      service: service,
      a_call_id: a_call_id,
      b_call_id: b_call_id,
      meta: Util.opt(opts, :meta)
    }

    state = %{bridge: bridge, req: req, uac: nil, ack: nil, pending: %{}}
    {:ok, state, {:continue, {:invite, uri, opts}}}
  end

  @impl true
  def handle_continue({:invite, uri, opts}, %{bridge: bridge, req: req} = state) do
    {sdp_opts, early_offer?} =
      case body_opts(req, :a, bridge) do
        [] -> {[], false}
        body -> {body, true}
      end

    uac_opts =
      [:async, call_id: bridge.b_call_id, callback: callback(:invite)] ++
        from_opt(req, opts) ++ copy_headers(req, opts) ++ sdp_opts ++ user_opts(opts)

    case UAC.invite(bridge.service, uri, uac_opts) do
      {:async, handle} ->
        {:noreply, %{state | uac: handle, ack: if(early_offer?, do: nil, else: :pending)}}

      {:error, error} ->
        Caracola.reply(req, :service_unavailable)
        stop({:error, error}, state)
    end
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, {:ok, state.bridge}, state}

  def handle_call(:hangup, _from, %{bridge: %{status: :calling}} = state) do
    UAC.cancel(state.uac)
    Caracola.reply(state.req, :request_terminated)
    {:stop, :normal, :ok, update(state, {:stop, :hangup})}
  end

  def handle_call(:hangup, _from, %{bridge: bridge} = state) do
    for dialog <- [bridge.a, bridge.b], do: UAC.bye(dialog, [:async])
    {:stop, :normal, :ok, update(state, {:stop, :hangup})}
  end

  @impl true
  # Responses of the B leg
  def handle_info({:uac, :invite, {:resp, code, resp}}, state) when code < 200 do
    Caracola.reply(state.req, {code, reply_opts(resp, :b, state.bridge)})
    {:noreply, state}
  end

  def handle_info({:uac, :invite, {:resp, code, resp}}, %{bridge: bridge} = state)
      when code < 300 do
    b = Dialog.handle(resp)
    bridge = %{bridge | a: Dialog.handle(state.req), b: b, status: :answered}
    state = %{state | bridge: bridge}
    if state.ack == nil, do: UAC.ack(b)

    case Caracola.reply(state.req, {code, reply_opts(resp, :b, bridge)}) do
      :ok ->
        {:noreply, update(state, :answered)}

      {:error, error} ->
        # The A leg is gone (cancelled meanwhile)
        if state.ack == :pending, do: UAC.ack(b)
        UAC.bye(b, [:async])
        stop({:error, error}, state)
    end
  end

  def handle_info({:uac, :invite, {:resp, code, resp}}, state) do
    reply = if code < 400, do: :temporarily_unavailable, else: {code, reply_opts(resp, nil, nil)}
    Caracola.reply(state.req, reply)
    stop({:rejected, code}, state)
  end

  def handle_info({:uac, :invite, {:error, error}}, state) do
    Caracola.reply(state.req, if(error == :timeout, do: :timeout, else: :service_unavailable))
    stop({:error, error}, state)
  end

  # Responses to requests forwarded to the other leg
  def handle_info({:uac, {:forward, ref}, reply}, state) do
    case {reply, Map.pop(state.pending, ref)} do
      {{:resp, code, _resp}, _} when code < 200 ->
        {:noreply, state}

      {_, {nil, _}} ->
        {:noreply, state}

      {{:resp, code, resp}, {{req, leg}, pending}} ->
        Caracola.reply(req, {code, reply_opts(resp, other(leg), state.bridge)})
        {:noreply, %{state | pending: pending}}

      {{:error, error}, {{req, _leg}, pending}} ->
        Caracola.reply(req, if(error == :timeout, do: :timeout, else: :internal_error))
        {:noreply, %{state | pending: pending}}
    end
  end

  # Requests and events of the legs, from the plugin callbacks
  def handle_info({:leg, call_id, msg}, state), do: leg(leg(call_id, state), msg, state)

  def handle_info(_msg, state), do: {:noreply, state}

  ## ===================================================================
  ## Legs
  ## ===================================================================

  defp leg(:a, :cancel, %{bridge: %{status: :calling}} = state) do
    UAC.cancel(state.uac)
    stop(:cancelled, state)
  end

  defp leg(leg, {:bye, _req}, %{bridge: %{status: :answered} = bridge} = state) do
    UAC.bye(dialog(other(leg), bridge), [:async])
    stop({:bye, leg}, state)
  end

  defp leg(:a, {:ack, %Message{} = req}, %{ack: :pending, bridge: bridge} = state) do
    UAC.ack(bridge.b, body_opts(req, :a, bridge))
    {:noreply, %{state | ack: nil}}
  end

  defp leg(leg, {:request, req}, state), do: forward(leg, req, state)

  # Only the end of the dialogs of the bridge counts: during the call, the
  # early dialogs of the B leg end without ending it
  defp leg(leg, {:dialog_stop, dialog, reason}, %{bridge: bridge} = state) do
    cond do
      bridge.status == :calling and leg == :a ->
        UAC.cancel(state.uac)
        stop({:dialog_stop, leg, reason}, state)

      bridge.status == :answered and dialog == dialog(leg, bridge) ->
        UAC.bye(dialog(other(leg), bridge), [:async])
        stop({:dialog_stop, leg, reason}, state)

      true ->
        {:noreply, state}
    end
  end

  defp leg(_leg, _msg, state), do: {:noreply, state}

  defp forward(_leg, req, %{bridge: %{status: :calling}} = state) do
    Caracola.reply(req, :request_pending)
    {:noreply, state}
  end

  # A re-INVITE without offer gets the last SDP sent to that leg
  defp forward(leg, %Message{class: {:req, :invite}, body: ""} = req, state) do
    sdp =
      case Dialog.get(dialog(leg, state.bridge)) do
        {:ok, %Dialog{invite: %{local_sdp: %SDP{} = sdp}}} -> SDP.increment(sdp)
        _ -> nil
      end

    Caracola.reply(
      req,
      if(sdp, do: {:ok, body: sdp}, else: {:not_acceptable, "305 Incompatible media format"})
    )

    {:noreply, state}
  end

  defp forward(leg, %Message{class: {:req, method}} = req, %{bridge: bridge} = state) do
    ref = make_ref()
    ack = if method == :invite, do: [:auto_2xx_ack], else: []
    opts = [:async, callback: callback({:forward, ref})] ++ ack ++ body_opts(req, leg, bridge)

    case UAC.request(dialog(other(leg), bridge), method, opts) do
      {:async, _handle} ->
        {:noreply, %{state | pending: Map.put(state.pending, ref, {req, leg})}}

      {:error, :request_pending} ->
        Caracola.reply(req, :request_pending)
        {:noreply, state}

      {:error, _error} ->
        Caracola.reply(req, :unknown_dialog)
        {:noreply, state}
    end
  end

  defp leg(call_id, %{bridge: %{a_call_id: call_id}}), do: :a
  defp leg(_call_id, _state), do: :b

  defp other(:a), do: :b
  defp other(:b), do: :a

  defp dialog(:a, bridge), do: bridge.a
  defp dialog(:b, bridge), do: bridge.b

  ## ===================================================================
  ## Util
  ## ===================================================================

  defp callback(tag) do
    pid = self()
    fn reply -> send(pid, {:uac, tag, reply}) end
  end

  # The body of a message to relay from a leg: SDPs go through
  # sip_b2bua_sdp/3, other bodies keep their Content-Type
  defp body_opts(%Message{body: ""}, _from, _bridge), do: []

  defp body_opts(%Message{} = msg, from, bridge) do
    case SDP.from_message(msg) do
      %SDP{} = sdp when bridge != nil ->
        [body: bridge.service.sip_b2bua_sdp(sdp, from, bridge)]

      _ ->
        content_type =
          if msg.content_type,
            do: [content_type: IO.iodata_to_binary(Tokens.encode(msg.content_type))],
            else: []

        [body: msg.body] ++ content_type
    end
  end

  defp reply_opts(%Message{class: {:resp, _, phrase}} = resp, from, bridge) do
    phrase = if phrase in [nil, ""], do: [], else: [reason_phrase: phrase]
    body = if from, do: body_opts(resp, from, bridge), else: []
    phrase ++ body
  end

  defp from_opt(req, opts) do
    case Util.opt(opts, :from) do
      nil ->
        [
          from: %{
            req.from
            | ext_params: Enum.reject(req.from.ext_params, &(elem(&1, 0) == "tag"))
          }
        ]

      from ->
        [from: from]
    end
  end

  defp copy_headers(req, opts) do
    for name <- Util.opt(opts, :copy_headers, []),
        value <- Message.header(req, name),
        do: {:add, name, value}
  end

  defp user_opts(opts),
    do: Enum.reject(opts, &match?({key, _} when key in [:from, :copy_headers, :meta], &1))

  defp update(%{bridge: bridge} = state, event) do
    bridge.service.sip_b2bua_update(event, bridge)
    state
  rescue
    error ->
      Logger.warning("error in sip_b2bua_update: " <> Exception.message(error))
      state
  end

  defp stop(reason, state), do: {:stop, :normal, update(state, {:stop, reason})}
end
