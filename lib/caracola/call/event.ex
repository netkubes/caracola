defmodule Caracola.Call.Event do
  @moduledoc false
  # Subscriptions inside dialogs (RFC 6665): creation by SUBSCRIBE, REFER
  # and NOTIFY transactions, state from Subscription-State, and timers N
  # (no NOTIFY after the SUBSCRIBE), expiration and middle (refresh).
  # Port of NkSIP's nksip_call_event.
  #
  # A SUBSCRIBE sent outside a dialog creates a "provisional event" for 64*T1,
  # so that a NOTIFY arriving before the 2xx response is accepted (and
  # creates the dialog and the subscription).

  alias Caracola.{Call, Dialog, Message, Subscription}

  ## ===================================================================
  ## Client
  ## ===================================================================

  @doc false
  # A NOTIFY must belong to one of our server subscriptions
  def uac_pre_request(%Message{class: {:req, :notify}} = req, dialog) do
    case find(dialog, req) do
      %Subscription{class: :uas} -> :ok
      _ -> {:error, :unknown_subscription}
    end
  end

  def uac_pre_request(_req, _dialog), do: :ok

  @doc false
  # Response to a SUBSCRIBE, REFER or NOTIFY we sent
  def uac_response(%Message{class: {:req, method}} = req, resp, dialog, call)
      when method in [:subscribe, :notify, :refer] do
    {:resp, code, _} = resp.class

    case find(dialog, req) do
      %Subscription{} = subs ->
        if own?(subs, method, :uac),
          do: do_response(method, code, req, resp, subs, dialog, call),
          else: dialog

      nil when code in 200..299 and method in [:subscribe, :refer] ->
        subs = create(:uac, req, dialog, call)
        do_response(method, code, req, resp, subs, dialog, call)

      _ ->
        dialog
    end
  end

  def uac_response(_req, _resp, dialog, _call), do: dialog

  ## ===================================================================
  ## Server
  ## ===================================================================

  @doc false
  # A SUBSCRIBE, REFER or NOTIFY received in a dialog
  def uas_request(%Message{class: {:req, method}} = req, dialog, call)
      when method in [:subscribe, :notify, :refer] do
    case find(dialog, req) do
      %Subscription{} = subs ->
        if own?(subs, method, :uas), do: {:ok, dialog}, else: {:error, :no_transaction}

      nil ->
        new_request(method, req, dialog, call)
    end
  end

  def uas_request(_req, dialog, _call), do: {:ok, dialog}

  # A REFER subscription is only created by the REFER
  defp new_request(:subscribe, req, dialog, _call),
    do: if(refer?(req), do: {:error, :forbidden}, else: {:ok, dialog})

  defp new_request(:refer, _req, dialog, _call), do: {:ok, dialog}

  defp new_request(:notify, req, dialog, call),
    do: if(prov_event?(req, call), do: {:ok, dialog}, else: {:error, :no_transaction})

  # Subscriptions are of the class of the SUBSCRIBE transaction, NOTIFY goes
  # in the opposite direction
  defp own?(%Subscription{class: class}, :notify, side), do: class != side
  defp own?(%Subscription{class: class}, _method, side), do: class == side

  defp refer?(%Message{event: {type, _}}), do: Caracola.Util.ascii_downcase(type) == "refer"
  defp refer?(_req), do: false

  @doc false
  # Response sent to a SUBSCRIBE, REFER or NOTIFY
  def uas_response(%Message{class: {:req, method}} = req, resp, dialog, call)
      when method in [:subscribe, :notify, :refer] do
    {:resp, code, _} = resp.class

    case find(dialog, req) do
      %Subscription{} = subs ->
        if own?(subs, method, :uas),
          do: do_response(method, code, req, resp, subs, dialog, call),
          else: dialog

      nil when code in 200..299 ->
        subs = create(if(method == :notify, do: :uac, else: :uas), req, dialog, call)
        do_response(method, code, req, resp, subs, dialog, call)

      _ ->
        dialog
    end
  end

  def uas_response(_req, _resp, dialog, _call), do: dialog

  ## ===================================================================
  ## Responses
  ## ===================================================================

  defp do_response(_method, code, _req, _resp, _subs, dialog, _call) when code < 200, do: dialog

  defp do_response(method, code, req, resp, subs, dialog, call)
       when method in [:subscribe, :refer] and code < 300,
       do: update({:subscribe, req, resp}, subs, dialog, call)

  # RFC 5057: these responses end the subscription
  defp do_response(method, code, _req, _resp, subs, dialog, call)
       when method in [:subscribe, :refer] do
    if subs.answered == nil or code in [405, 408, 481, 501],
      do: update({:terminated, {:code, code}, nil}, subs, dialog, call),
      else: store(subs, dialog)
  end

  defp do_response(:notify, code, req, _resp, subs, dialog, call) when code < 300,
    do: update({:notify, req}, subs, dialog, call)

  defp do_response(:notify, code, _req, _resp, subs, dialog, call)
       when code in [405, 408, 481, 501],
       do: update({:terminated, {:code, code}, nil}, subs, dialog, call)

  defp do_response(_method, _code, _req, _resp, _subs, dialog, _call), do: dialog

  ## ===================================================================
  ## State
  ## ===================================================================

  # Expiration negotiated by SUBSCRIBE (the lowest of request and response)
  defp update({:subscribe, %Message{class: {:req, method}} = req, resp}, subs, dialog, call) do
    cancel_timers(subs)
    default = default_expires(method, call)
    expires = min(req.expires || default, resp.expires || default)
    # Timer N waits for the first NOTIFY
    timer_n = if subs.status == :init, do: start(64 * t1(call), :timeout, subs, dialog)

    subs = %{subs | expires: expires, timer_n: timer_n}
    store(start_expire(subs, expires, dialog, call), dialog)
  end

  defp update({:notify, req}, subs, dialog, call) do
    case Subscription.state(req) do
      :invalid -> update({:terminated, {:code, 400}, nil}, subs, dialog, call)
      state -> update(state, subs, dialog, call)
    end
  end

  defp update({status, expires}, subs, dialog, call) when status in [:active, :pending] do
    if status != subs.status, do: notify(status, subs, dialog, call)
    cancel_timers(subs)
    expires = expires || subs.expires || 0

    subs = %{
      subs
      | status: status,
        expires: expires,
        answered: subs.answered || System.os_time(:second),
        timer_n: nil
    }

    store(start_expire(subs, expires, dialog, call), dialog)
  end

  defp update({:terminated, reason, retry}, subs, dialog, call) do
    cancel_timers(subs)
    status = if retry, do: {:terminated, reason, retry}, else: {:terminated, reason}
    notify(status, subs, dialog, call)
    store(%{subs | status: {:terminated, reason}}, dialog)
  end

  defp start_expire(subs, 0, _dialog, _call), do: %{subs | timer_expire: nil, timer_middle: nil}

  defp start_expire(subs, expires, dialog, call) do
    offset = call.config[:event_expires_offset] || 5

    %{
      subs
      | timer_expire: start(1000 * (expires + offset), :timeout, subs, dialog),
        timer_middle: start(500 * expires, :middle, subs, dialog)
    }
  end

  defp default_expires(:refer, call), do: call.config[:timer_c] || 180
  defp default_expires(_method, call), do: call.config[:event_expires] || 60

  @doc false
  # Forced end of a subscription (the dialog is stopped)
  def stop(%Subscription{} = subs, dialog, call),
    do: update({:terminated, :forced, nil}, subs, dialog, call)

  @doc false
  # Called when a timer of a subscription is fired
  def timer(type, id, ref, %Dialog{} = dialog, call) do
    case Subscription.find(dialog, id) do
      %Subscription{} = subs when type == :middle ->
        if {type, ref} == subs.timer_middle, do: notify(:middle_timer, subs, dialog, call)
        call

      %Subscription{} = subs ->
        if {type, ref} in [subs.timer_n, subs.timer_expire] do
          dialog = update({:terminated, :timeout, nil}, subs, dialog, call)
          Call.Dialog.store(dialog, call)
        else
          call
        end

      nil ->
        call
    end
  end

  ## ===================================================================
  ## In-dialog requests
  ## ===================================================================

  @doc false
  # Options of a SUBSCRIBE or NOTIFY for a subscription: Event, Expires (the
  # current one) and Subscription-State, with the remaining time
  def request_opts(method, id, opts, dialog, call) do
    case Subscription.find(dialog, id) do
      nil -> {:error, :unknown_subscription}
      subs -> {:ok, request_opts(method, opts, subs, call)}
    end
  end

  defp request_opts(:notify, opts, subs, call) do
    state =
      case Caracola.Util.opt(opts, :subscription_state, :active) do
        state when state in [:active, :pending] -> remaining(state, subs, call)
        {state, _} when state in [:active, :pending] -> remaining(state, subs, call)
        state -> state
      end

    opts = Enum.reject(opts, &match?({:subscription_state, _}, &1))
    [event: subs.event, subscription_state: state] ++ opts
  end

  defp request_opts(_method, opts, subs, _call),
    do: [event: subs.event, expires: subs.expires] ++ opts

  # Without expiration, the subscription has timed out
  defp remaining(state, %Subscription{timer_expire: {_, ref}}, call) do
    case :erlang.read_timer(ref) do
      ms when is_integer(ms) ->
        {state, round(ms / 1000) - (call.config[:event_expires_offset] || 5)}

      false ->
        {:terminated, :timeout}
    end
  end

  defp remaining(_state, _subs, _call), do: {:terminated, :timeout}

  ## ===================================================================
  ## Provisional events
  ## ===================================================================

  @doc false
  # A SUBSCRIBE or REFER sent outside a dialog
  def create_prov_event(%Message{} = req, call) do
    key = {Subscription.id(req), req.from_tag}
    Process.send_after(self(), {:remove_prov_event, key}, 64 * t1(call))
    %{call | events: MapSet.put(call.events, key)}
  end

  @doc false
  def remove_prov_event(%Message{} = req, call),
    do: remove_prov_event({Subscription.id(req), req.from_tag}, call)

  def remove_prov_event(key, call), do: %{call | events: MapSet.delete(call.events, key)}

  @doc false
  # A NOTIFY for a SUBSCRIBE we sent (its To tag is our From tag)
  def prov_event?(%Message{class: {:req, :notify}} = req, call),
    do: MapSet.member?(call.events, {Subscription.id(req), req.to_tag})

  def prov_event?(_req, _call), do: false

  ## ===================================================================
  ## Util
  ## ===================================================================

  @doc false
  # A received NOTIFY of a REFER without id (as sent by pjsip) belongs to
  # the first REFER of its dialog (RFC 3515 §2.4.6): the id is added
  def refer_id(%Message{class: {:req, :notify}, event: {type, params}} = req, call) do
    with "refer" <- Caracola.Util.ascii_downcase(type),
         false <- List.keymember?(params, "id", 0),
         %Dialog{} = dialog <- Call.Dialog.find(req.dialog_id, call),
         %Subscription{event: {_, [{"id", id}]}} <- find(dialog, req) do
      %{req | event: {type, params ++ [{"id", id}]}}
    else
      _ -> req
    end
  end

  def refer_id(req, _call), do: req

  # NOTIFYs of a REFER without id belong to the first REFER of the dialog
  defp find(dialog, req) do
    with nil <- Subscription.find(dialog, Subscription.id(req)),
         %Message{class: {:req, :notify}, event: {type, params}} <- req,
         "refer" <- Caracola.Util.ascii_downcase(type),
         false <- List.keymember?(params, "id", 0) do
      dialog.subscriptions
      |> Enum.filter(&match?({"refer", _}, &1.event))
      |> Enum.min_by(&refer_cseq/1, fn -> nil end)
    else
      _ -> Subscription.find(dialog, Subscription.id(req))
    end
  end

  defp refer_cseq(%Subscription{event: {"refer", params}}) do
    {_, id} = List.keyfind(params, "id", 0)
    String.to_integer(id)
  end

  defp create(class, %Message{class: {:req, method}} = req, dialog, call) do
    event =
      if method == :refer,
        do: {"refer", [{"id", Integer.to_string(elem(req.cseq, 0))}]},
        else: req.event

    id = Subscription.id(req)

    subs = %Subscription{
      id: id,
      service: dialog.service,
      call_id: dialog.call_id,
      dialog_id: dialog.id,
      event: event,
      class: class
    }

    subs = %{subs | timer_n: start(64 * t1(call), :timeout, subs, dialog)}
    notify(:init, subs, dialog, call)
    subs
  end

  # Terminated subscriptions are removed, others keep their position
  defp store(%Subscription{status: {:terminated, _}, id: id}, dialog),
    do: %{dialog | subscriptions: Enum.reject(dialog.subscriptions, &(&1.id == id))}

  defp store(%Subscription{id: id} = subs, dialog) do
    subscriptions =
      if Enum.any?(dialog.subscriptions, &(&1.id == id)),
        do: Enum.map(dialog.subscriptions, &if(&1.id == id, do: subs, else: &1)),
        else: dialog.subscriptions ++ [subs]

    %{dialog | subscriptions: subscriptions}
  end

  defp notify(status, subs, dialog, call) do
    Call.callback(call, :sip_dialog_update, [{:subscription_status, status, subs}, dialog, call])
  end

  defp t1(call), do: call.config[:timer_t1] || 500

  defp start(time, type, %Subscription{id: id}, %Dialog{id: dialog_id}),
    do: {type, :erlang.start_timer(round(time), self(), {:dialog, {:event, type, id}, dialog_id})}

  defp cancel_timers(%Subscription{} = subs) do
    for {_, ref} <- [subs.timer_n, subs.timer_expire, subs.timer_middle],
        do: :erlang.cancel_timer(ref)
  end
end
