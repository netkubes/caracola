defmodule Caracola.Call.Dialog do
  @moduledoc false
  # Dialogs inside the call process: creation, state changes, target and
  # route set updates, offer/answer results and timers. Port of NkSIP's
  # nksip_call_dialog.
  #
  # Each dialog has, while it has an INVITE usage, up to two timers: the
  # retransmission of the 2xx response (accepted_uas) and a timeout timer,
  # which ends early dialogs, sends BYE if the ACK never arrives and
  # refreshes the dialog timeout (dialog_timeout) after every 2xx.

  require Logger

  alias Caracola.{Call, Dialog, Message, SDP, URI}
  alias Caracola.Call.{DialogUAC, Event, SessionTimer, Transp, UAC}
  alias Caracola.Dialog.Invite

  ## ===================================================================
  ## Dialogs
  ## ===================================================================

  @doc false
  # New dialog from a dialog-creating request and its response
  def create(class, %Message{} = req, %Message{} = resp, %Call{} = call) do
    now = System.os_time(:second)
    {cseq, _} = resp.cseq

    dialog = %Dialog{
      id: Dialog.id(class, resp),
      service: call.service,
      call_id: call.call_id,
      created: now,
      updated: now,
      secure:
        match?(%{transport: t} when t in [:tls, :wss], resp.port) and req.ruri.scheme == :sips,
      caller_tag: resp.from_tag
    }

    dialog =
      case class do
        :uac -> %{dialog | local_seq: cseq, local_uri: resp.from, remote_uri: resp.to}
        :uas -> %{dialog | remote_seq: cseq, local_uri: resp.to, remote_uri: resp.from}
      end

    Logger.debug("dialog #{dialog.id} (#{class}) created")
    meta = %{service: call.service, call_id: call.call_id, dialog_id: dialog.id}
    dialog = put_in(dialog.meta[:start_time], Caracola.Telemetry.start(:dialog, meta))
    notify_dialog(:start, dialog, call)
    dialog
  end

  @doc false
  # Adds the INVITE usage to a new dialog. Its first status (with a
  # provisional response) is notified as the later ones.
  def new_invite(%Dialog{} = dialog, %Invite{} = invite, code, call) do
    dialog = %{dialog | invite: invite}
    if code < 200, do: notify_dialog({:invite_status, invite.status}, dialog, call)
    dialog
  end

  @doc false
  def find(nil, _call), do: nil
  def find(id, %Call{dialogs: dialogs}), do: Map.get(dialogs, id)

  @doc false
  # Stores a dialog in the call, or removes it if it has no usages left
  def store(%Dialog{invite: nil, subscriptions: []} = dialog, %Call{} = call) do
    notify_dialog(:stop, dialog, call)

    if start_time = dialog.meta[:start_time] do
      meta = %{service: call.service, call_id: call.call_id, dialog_id: dialog.id}
      Caracola.Telemetry.stop(:dialog, start_time, meta)
    end

    %{call | dialogs: Map.delete(call.dialogs, dialog.id)}
  end

  def store(%Dialog{} = dialog, %Call{} = call),
    do: %{call | dialogs: Map.put(call.dialogs, dialog.id, dialog)}

  @doc false
  # Ends all the usages of a dialog
  def stop(reason, %Dialog{} = dialog, call) do
    dialog = Enum.reduce(dialog.subscriptions, dialog, &Event.stop(&1, &2, call))

    if dialog.invite,
      do: update({:invite, {:stop, reason}}, dialog, call),
      else: store(dialog, call)
  end

  @doc false
  # Updates a dialog after a request or response and stores it
  def update({:invite, {:stop, reason}}, %Dialog{invite: invite} = dialog, call) do
    cancel_timers(invite)
    dialog = cancel_refresh(dialog)
    notify_dialog({:invite_status, {:stop, reason(reason)}}, dialog, call)
    if invite.media_started, do: notify_session(:stop, dialog, call)
    store(%{dialog | invite: nil}, call)
  end

  def update({:invite, status}, %Dialog{invite: invite} = dialog, call) do
    dialog =
      if status == invite.status do
        dialog
      else
        Logger.debug("dialog #{dialog.id} #{invite.status} -> #{status}")
        dialog = %{dialog | invite: %{invite | status: status}}
        notify_dialog({:invite_status, status}, dialog, call)
        dialog
      end

    dialog = status_update(status, dialog, call)

    dialog =
      if status in [:accepted_uac, :accepted_uas],
        do: %{dialog | blocked_route_set: true},
        else: dialog

    %Invite{class: class, request: req, response: resp} = dialog.invite
    store(timer_update({class, req, resp}, dialog, call), call)
  end

  def update({:update, class, req, resp}, dialog, call) do
    dialog
    |> target_update(class, req, resp, call)
    |> session_update(call)
    |> then(&timer_update({class, req, resp}, &1, call))
    |> store(call)
  end

  # The first NOTIFY fixes the route set
  def update({method, class, req, resp}, dialog, call) when method in [:subscribe, :notify] do
    dialog =
      dialog
      |> route_update(class, req, resp)
      |> target_update(class, req, resp, call)

    dialog = if method == :notify, do: %{dialog | blocked_route_set: true}, else: dialog
    store(dialog, call)
  end

  # Offer/answer completed with a PRACK
  def update(:prack, dialog, call), do: store(session_update(dialog, call), call)

  def update(:none, dialog, call), do: store(dialog, call)

  defp status_update(status, %Dialog{invite: invite} = dialog, call)
       when status in [:proceeding_uac, :proceeding_uas, :accepted_uac, :accepted_uas] do
    %Invite{class: class, request: req, response: resp} = invite

    dialog
    |> route_update(class, req, resp)
    |> target_update(class, req, resp, call)
    |> session_update(call)
  end

  defp status_update(:confirmed, dialog, call), do: session_update(dialog, call)

  defp status_update(:bye, %Dialog{invite: %Invite{media_started: true} = invite} = dialog, call) do
    notify_session(:stop, dialog, call)
    %{dialog | invite: %{invite | media_started: false}}
  end

  defp status_update(:bye, dialog, _call), do: dialog

  # The remote target is the Contact of the other party, and the local one
  # our own (RFC 3261 §12.2)
  defp target_update(dialog, class, req, resp, call) do
    {local_target, remote_target} = targets(dialog, class, req, resp)

    if dialog.remote_target != nil and remote_target != dialog.remote_target,
      do: notify_dialog(:target_update, dialog, call)

    {:resp, code, _} = resp.class
    now = System.os_time(:second)

    %{
      dialog
      | updated: now,
        local_target: local_target,
        remote_target: remote_target,
        early: dialog.early and code in 100..199,
        invite: invite_target(dialog.invite, local_target, remote_target, code, now)
    }
  end

  defp targets(dialog, class, req, resp) do
    {remote_targets, local_targets} =
      if class == :uas,
        do: {req.contacts, resp.contacts},
        else: {resp.contacts, req.contacts}

    remote_target =
      case remote_targets do
        [target] when dialog.secure -> %{target | scheme: :sips}
        [target] -> target
        _ -> dialog.remote_target
      end

    local_target =
      case local_targets do
        [target] -> target
        _ -> dialog.local_target
      end

    {local_target, remote_target}
  end

  # The stored INVITE gets the new target, so that the final response of an
  # INVITE in progress uses it
  defp invite_target(%Invite{} = invite, local_target, remote_target, code, now) do
    answered = if invite.answered == nil and code >= 200, do: now, else: invite.answered
    target = if invite.class == :uas, do: remote_target, else: local_target
    %{invite | answered: answered, request: %{invite.request | contacts: [target]}}
  end

  defp invite_target(nil, _local, _remote, _code, _now), do: nil

  # The route set is fixed by the first 2xx response
  defp route_update(%Dialog{blocked_route_set: false} = dialog, class, req, resp) do
    route_set =
      case class do
        :uas -> record_route(req)
        :uac -> Enum.reverse(record_route(resp))
      end

    %{dialog | route_set: route_set}
  end

  defp route_update(dialog, _class, _req, _resp), do: dialog

  defp record_route(msg) do
    Enum.flat_map(Message.header(msg, "record-route"), fn value ->
      case URI.parse(value) do
        {:ok, uris} -> uris
        :error -> []
      end
    end)
  end

  # Completed offer/answer exchange: the new SDPs become the session ones
  defp session_update(
         %Dialog{
           invite:
             %Invite{
               sdp_offer: {offer_party, _, %SDP{} = offer},
               sdp_answer: {answer_party, _, %SDP{} = answer}
             } = invite
         } = dialog,
         call
       )
       when offer_party != answer_party do
    {local, remote} = if offer_party == :local, do: {offer, answer}, else: {answer, offer}

    cond do
      not invite.media_started ->
        notify_session({:start, local, remote}, dialog, call)

      SDP.newer?(remote, invite.remote_sdp) or SDP.newer?(local, invite.local_sdp) ->
        notify_session({:update, local, remote}, dialog, call)

      true ->
        :ok
    end

    invite = %{
      invite
      | local_sdp: local,
        remote_sdp: remote,
        media_started: true,
        sdp_offer: nil,
        sdp_answer: nil
    }

    %{dialog | invite: invite}
  end

  defp session_update(dialog, _call), do: dialog

  ## ===================================================================
  ## Timers
  ## ===================================================================

  # After a 2xx the dialog timeout is restarted: the session interval if a
  # session timer was negotiated (the refresher gets a notification at half
  # of it, the other party waits a bit less than the whole interval), or
  # dialog_timeout. After a non-2xx the dialog returns to confirmed, and the
  # timeout timer is kept.
  defp timer_update(
         {class, req, %Message{class: {:resp, code, _}} = resp},
         %Dialog{invite: %Invite{status: :confirmed} = invite} = dialog,
         call
       )
       when code in 200..299 do
    cancel(invite.retrans_timer)
    cancel(invite.timeout_timer)
    dialog = cancel_refresh(dialog)

    role =
      if SessionTimer.enabled?(call.config) and req != nil,
        do: SessionTimer.role(class, req, resp),
        else: :none

    {timeout, meta} =
      case role do
        {:refresher, se} ->
          refresh = start(500 * se, :invite_refresh, dialog)
          {1000 * se, %{dialog.meta | session_expires: se, refresh_timer: refresh}}

        {:refreshed, se} ->
          {round(1000 * (se - min(32, se / 3))), %{dialog.meta | session_expires: se}}

        :none ->
          {1000 * (call.config[:dialog_timeout] || 1800), %{dialog.meta | session_expires: nil}}
      end

    invite = %{
      invite
      | retrans_timer: nil,
        timeout_timer: start(timeout, :invite_timeout, dialog)
    }

    %{dialog | invite: invite, meta: meta}
  end

  defp timer_update(_info, %Dialog{invite: %Invite{status: :confirmed} = invite} = dialog, _call),
    do: %{dialog | invite: %{invite | retrans_timer: cancel(invite.retrans_timer)}}

  defp timer_update(
         _info,
         %Dialog{invite: %Invite{status: :accepted_uas} = invite} = dialog,
         call
       ) do
    dialog = cancel_refresh(dialog)
    t1 = t1(call)
    cancel(invite.retrans_timer)
    cancel(invite.timeout_timer)

    invite = %{
      invite
      | retrans_timer: start(t1, :invite_retrans, dialog),
        next_retrans: 2 * t1,
        timeout_timer: start(64 * t1, :invite_timeout, dialog)
    }

    %{dialog | invite: invite}
  end

  # Early dialogs last as the INVITE transaction (timer C)
  defp timer_update(_info, %Dialog{invite: %Invite{status: status} = invite} = dialog, call)
       when status in [:proceeding_uac, :proceeding_uas] do
    cancel(invite.retrans_timer)
    cancel(invite.timeout_timer)
    time = 1_000 * (call.config[:timer_c] || 180)
    invite = %{invite | retrans_timer: nil, timeout_timer: start(time, :invite_timeout, dialog)}
    %{dialog | invite: invite}
  end

  defp timer_update(_info, %Dialog{invite: invite} = dialog, call) do
    dialog = cancel_refresh(dialog)
    cancel(invite.retrans_timer)
    cancel(invite.timeout_timer)

    invite = %{
      invite
      | retrans_timer: nil,
        timeout_timer: start(64 * t1(call), :invite_timeout, dialog)
    }

    %{dialog | invite: invite}
  end

  @doc false
  # Called when a timer message arrives
  def fired({:event, type, subs_id}, id, ref, %Call{} = call) do
    case find(id, call) do
      %Dialog{} = dialog -> Event.timer(type, subs_id, ref, dialog, call)
      nil -> call
    end
  end

  def fired(:invite_refresh, id, ref, %Call{} = call) do
    case find(id, call) do
      %Dialog{invite: %Invite{} = invite, meta: %{refresh_timer: {:invite_refresh, ^ref}}} =
          dialog ->
        notify_dialog({:invite_refresh, invite.local_sdp}, dialog, call)
        store(%{dialog | meta: %{dialog.meta | refresh_timer: :expired}}, call)

      _ ->
        call
    end
  end

  def fired(tag, id, ref, %Call{} = call) do
    with %Dialog{invite: %Invite{} = invite} = dialog <- find(id, call),
         true <- {tag, ref} in [invite.timeout_timer, invite.retrans_timer] do
      invite =
        if tag == :invite_retrans,
          do: %{invite | retrans_timer: nil},
          else: %{invite | timeout_timer: nil}

      timer(tag, %{dialog | invite: invite}, call)
    else
      _ -> call
    end
  end

  # The 2xx response is retransmitted until the ACK arrives (RFC 3261 §13.3.1.4)
  defp timer(
         :invite_retrans,
         %Dialog{invite: %Invite{status: :accepted_uas} = invite} = dialog,
         call
       ) do
    case Transp.resend_response(invite.response) do
      {:ok, _} ->
        next = invite.next_retrans

        invite = %{
          invite
          | retrans_timer: start(next, :invite_retrans, dialog),
            next_retrans: min(2 * next, call.config[:timer_t2] || 4_000)
        }

        store(%{dialog | invite: invite}, call)

      {:error, error} ->
        Logger.notice("dialog #{dialog.id} could not resend response: #{inspect(error)}")
        update({:invite, {:stop, :ack_timeout}}, dialog, call)
    end
  end

  defp timer(:invite_timeout, %Dialog{invite: %Invite{status: status}} = dialog, call)
       when status in [:proceeding_uac, :proceeding_uas, :bye],
       do: update({:invite, {:stop, :timeout}}, dialog, call)

  # No ACK, or dialog timeout: BYE
  defp timer(:invite_timeout, dialog, call) do
    Logger.notice("dialog #{dialog.id} (#{dialog.invite.status}) timeout, sending BYE")
    notify_dialog(:invite_timeout, dialog, call)
    call = update({:invite, :bye}, dialog, call)
    opts = [{:reason, "SIP;cause=408;text=\"Dialog Timeout\""}]

    case DialogUAC.make(dialog.id, :bye, opts, call) do
      {:ok, ruri, opts, call} -> UAC.send_new(:bye, ruri, opts, nil, call)
      {:error, _} -> stop(:timeout, find(dialog.id, call), call)
    end
  end

  defp timer(_tag, dialog, call), do: store(dialog, call)

  defp t1(call), do: call.config[:timer_t1] || 500

  defp start(time, tag, %Dialog{id: id}),
    do: {tag, :erlang.start_timer(round(time), self(), {:dialog, tag, id})}

  defp cancel({_tag, ref}) do
    :erlang.cancel_timer(ref)
    nil
  end

  defp cancel(nil), do: nil

  defp cancel_refresh(%Dialog{meta: %{refresh_timer: refresh} = meta} = dialog) do
    if is_tuple(refresh), do: cancel(refresh)
    %{dialog | meta: %{meta | refresh_timer: nil}}
  end

  defp cancel_refresh(dialog), do: dialog

  @doc false
  # Values kept in the dialog (nil if there is no dialog)
  def get_meta(id, key, call) do
    case find(id, call) do
      %Dialog{meta: meta} -> Map.get(meta, key)
      nil -> nil
    end
  end

  @doc false
  def put_meta(id, key, value, call) do
    case find(id, call) do
      %Dialog{meta: meta} = dialog -> store(%{dialog | meta: Map.put(meta, key, value)}, call)
      nil -> call
    end
  end

  defp cancel_timers(%Invite{} = invite) do
    cancel(invite.retrans_timer)
    cancel(invite.timeout_timer)
  end

  ## ===================================================================
  ## Util
  ## ===================================================================

  @doc false
  def reason(486), do: :busy
  def reason(487), do: :cancelled
  def reason(503), do: :service_unavailable
  def reason(603), do: :declined
  def reason(other), do: other

  defp notify_dialog(event, dialog, call),
    do: Call.callback(call, :sip_dialog_update, [event, dialog, call])

  defp notify_session(event, dialog, call),
    do: Call.callback(call, :sip_session_update, [event, dialog, call])
end
