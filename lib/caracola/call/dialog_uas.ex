defmodule Caracola.Call.DialogUAS do
  @moduledoc false
  # Dialogs on the server side: requests received and responses sent inside
  # a dialog. Port of NkSIP's nksip_call_uas_dialog. See
  # Caracola.Call.DialogUAC for the offer/answer rules.

  alias Caracola.{Call, Dialog, Message, SDP, URI}
  alias Caracola.Call.Event
  alias Caracola.Dialog.Invite

  ## ===================================================================
  ## Requests
  ## ===================================================================

  @doc false
  # An in-dialog request has been received. Returns an error reply if it
  # must be rejected.
  def request(%Message{class: {:req, :ack}} = req, call), do: ack(req, call)

  def request(%Message{class: {:req, method}, cseq: {cseq, _}} = req, call) do
    case Call.Dialog.find(req.dialog_id, call) do
      %Dialog{remote_seq: remote_seq} when remote_seq > 0 and cseq < remote_seq ->
        {:error, {:internal_error, "Old CSeq in Dialog"}}

      %Dialog{} = dialog ->
        do_request(method, req, %{dialog | remote_seq: cseq}, call)

      # A NOTIFY can arrive before the response to our SUBSCRIBE
      nil ->
        if method == :notify and Event.prov_event?(req, call),
          do: {:ok, call},
          else: {:error, :no_transaction}
    end
  end

  defp do_request(:invite, req, %Dialog{invite: nil} = dialog, call),
    do: do_request(:invite, req, %{dialog | invite: %Invite{status: :confirmed}}, call)

  defp do_request(
         :invite,
         req,
         %Dialog{invite: %Invite{status: :confirmed} = invite} = dialog,
         call
       ) do
    case {SDP.from_message(req), invite.sdp_offer} do
      {%SDP{}, offer} when offer != nil ->
        {:error, :request_pending}

      {sdp, _} ->
        invite = %{
          invite
          | status: :proceeding_uas,
            class: :uas,
            request: req,
            response: nil,
            ack: nil,
            sdp_offer: if(sdp, do: {:remote, :invite, sdp}),
            sdp_answer: nil
        }

        {:ok, Call.Dialog.store(%{dialog | invite: invite}, call)}
    end
  end

  # Glare (RFC 3261 §14.2)
  defp do_request(:invite, _req, %Dialog{invite: %Invite{status: status}}, _call) do
    case status do
      status when status in [:proceeding_uac, :accepted_uac] -> {:error, :request_pending}
      status when status in [:proceeding_uas, :accepted_uas] -> {:error, retry()}
      _ -> {:error, :no_transaction}
    end
  end

  defp do_request(:bye, _req, %Dialog{invite: %Invite{}} = dialog, call),
    do: {:ok, Call.Dialog.update({:invite, :bye}, dialog, call)}

  defp do_request(
         :prack,
         req,
         %Dialog{invite: %Invite{status: :proceeding_uas} = invite} = dialog,
         call
       ) do
    case {invite.sdp_offer, SDP.from_message(req)} do
      {nil, %SDP{} = sdp} ->
        invite = %{invite | sdp_offer: {:remote, :prack, sdp}}
        {:ok, Call.Dialog.store(%{dialog | invite: invite}, call)}

      {{:local, :invite, _}, %SDP{} = sdp} ->
        invite = %{invite | sdp_answer: {:remote, :prack, sdp}}
        {:ok, Call.Dialog.update(:prack, %{dialog | invite: invite}, call)}

      _ ->
        {:ok, Call.Dialog.store(dialog, call)}
    end
  end

  defp do_request(:prack, _req, _dialog, _call), do: {:error, :request_pending}

  defp do_request(:update, req, %Dialog{invite: %Invite{} = invite} = dialog, call) do
    case {invite.sdp_offer, SDP.from_message(req)} do
      {nil, %SDP{} = sdp} ->
        invite = %{invite | sdp_offer: {:remote, :update, sdp}}
        {:ok, Call.Dialog.store(%{dialog | invite: invite}, call)}

      {nil, nil} ->
        {:ok, Call.Dialog.store(dialog, call)}

      {{:local, _, _}, _} ->
        {:error, :request_pending}

      {{:remote, _, _}, _} ->
        {:error, retry()}
    end
  end

  defp do_request(method, req, dialog, call) when method in [:subscribe, :notify, :refer] do
    with {:ok, dialog} <- Event.uas_request(req, dialog, call),
         do: {:ok, Call.Dialog.store(dialog, call)}
  end

  defp do_request(_method, _req, dialog, call), do: {:ok, Call.Dialog.store(dialog, call)}

  # ACK for a 2xx response
  defp ack(%Message{cseq: {cseq, _}} = req, call) do
    case Call.Dialog.find(req.dialog_id, call) do
      %Dialog{
        invite: %Invite{status: :accepted_uas, request: %Message{cseq: {^cseq, _}}} = invite
      } =
          dialog ->
        sdp = SDP.from_message(req)

        {offer, answer} =
          case invite.sdp_offer do
            {:local, :invite, _} when sdp != nil -> {invite.sdp_offer, {:remote, :ack, sdp}}
            {:local, :invite, _} -> {nil, nil}
            offer -> {offer, invite.sdp_answer}
          end

        invite = %{invite | ack: req, sdp_offer: offer, sdp_answer: answer}
        {:ok, Call.Dialog.update({:invite, :confirmed}, %{dialog | invite: invite}, call)}

      # Retransmission
      %Dialog{invite: %Invite{status: status}} when status in [:confirmed, :bye] ->
        {:ok, call}

      _ ->
        {:error, :no_transaction}
    end
  end

  defp retry do
    {500,
     [
       {:add, "retry-after", Enum.random(0..10)},
       reason_phrase: "Processing Previous INVITE"
     ]}
  end

  ## ===================================================================
  ## Responses
  ## ===================================================================

  @doc false
  # Before sending a response: sets its dialog id and, if it has no Contact,
  # uses the local target of the dialog
  def update_response(%Message{} = resp, opts, call) do
    resp = %{resp | dialog_id: Dialog.id(:uas, resp)}

    case {resp.contacts, Call.Dialog.find(resp.dialog_id, call)} do
      {[], %Dialog{local_target: %URI{} = target}} ->
        {%{resp | contacts: [target]}, List.delete(opts, :contact)}

      _ ->
        {resp, opts}
    end
  end

  @doc false
  # A response has been sent
  def response(%Message{class: {:req, method}} = req, %Message{} = resp, call) do
    {:resp, code, _} = resp.class

    case Call.Dialog.find(resp.dialog_id, call) do
      %Dialog{} = dialog ->
        do_response(method, code, req, resp, dialog, call)

      nil when method == :invite and code in 101..299 ->
        dialog = Call.Dialog.create(:uas, req, resp, call)
        offer = if sdp = SDP.from_message(req), do: {:remote, :invite, sdp}
        invite = %Invite{status: :proceeding_uas, class: :uas, request: req, sdp_offer: offer}

        do_response(
          method,
          code,
          req,
          resp,
          Call.Dialog.new_invite(dialog, invite, code, call),
          call
        )

      nil when method in [:subscribe, :notify, :refer] and code in 200..299 ->
        dialog = Call.Dialog.create(:uas, req, resp, call)
        do_response(method, code, req, resp, dialog, call)

      nil ->
        call
    end
  end

  # Dialog ending responses (RFC 5057)
  @stop_codes [404, 410, 416, 482, 483, 484, 485, 502, 604]

  defp do_response(_method, code, _req, _resp, _dialog, call) when code < 101, do: call

  defp do_response(_method, code, _req, _resp, dialog, call) when code in @stop_codes,
    do: Call.Dialog.stop(code, dialog, call)

  defp do_response(_method, 481, _req, _resp, %Dialog{invite: %Invite{}} = dialog, call),
    do: Call.Dialog.update({:invite, {:stop, 481}}, dialog, call)

  defp do_response(
         :invite,
         code,
         req,
         resp,
         %Dialog{invite: %Invite{status: :proceeding_uas} = invite} = dialog,
         call
       )
       when code < 300 do
    {offer, answer} = invite_answer(code, req, resp, invite)
    invite = %{invite | response: resp, sdp_offer: offer, sdp_answer: answer}
    status = if code < 200, do: :proceeding_uas, else: :accepted_uas
    Call.Dialog.update({:invite, status}, %{dialog | invite: invite}, call)
  end

  defp do_response(
         :invite,
         code,
         _req,
         resp,
         %Dialog{invite: %Invite{status: :proceeding_uas} = invite} = dialog,
         call
       ) do
    if invite.answered == nil do
      Call.Dialog.update({:invite, {:stop, code}}, dialog, call)
    else
      # A failed re-INVITE: back to confirmed
      offer =
        case invite.sdp_offer do
          {_, method, _} when method in [:invite, :prack] -> nil
          offer -> offer
        end

      invite = %{invite | response: resp, sdp_offer: offer}
      Call.Dialog.update({:invite, :confirmed}, %{dialog | invite: invite}, call)
    end
  end

  # A challenged BYE is sent again with credentials
  defp do_response(:bye, code, _req, _resp, dialog, call) when code in [401, 407],
    do: Call.Dialog.store(dialog, call)

  defp do_response(:bye, _code, req, _resp, %Dialog{invite: %Invite{}} = dialog, call) do
    reason = if req.from_tag == dialog.caller_tag, do: :caller_bye, else: :callee_bye
    Call.Dialog.update({:invite, {:stop, reason}}, dialog, call)
  end

  defp do_response(:prack, code, _req, resp, %Dialog{invite: %Invite{} = invite} = dialog, call)
       when code in 200..299 do
    case {invite.sdp_offer, SDP.from_message(resp)} do
      {{:remote, :prack, _}, %SDP{} = sdp} ->
        invite = %{invite | sdp_answer: {:local, :prack, sdp}}
        Call.Dialog.update(:prack, %{dialog | invite: invite}, call)

      {{:remote, :prack, _}, nil} ->
        Call.Dialog.store(%{dialog | invite: %{invite | sdp_offer: nil, sdp_answer: nil}}, call)

      _ ->
        Call.Dialog.store(dialog, call)
    end
  end

  defp do_response(:prack, _code, _req, _resp, %Dialog{invite: %Invite{} = invite} = dialog, call) do
    case invite.sdp_offer do
      {:remote, :prack, _} ->
        Call.Dialog.store(%{dialog | invite: %{invite | sdp_offer: nil, sdp_answer: nil}}, call)

      _ ->
        Call.Dialog.store(dialog, call)
    end
  end

  defp do_response(:update, code, req, resp, %Dialog{invite: %Invite{} = invite} = dialog, call)
       when code in 200..299 do
    {offer, answer} =
      case {invite.sdp_offer, SDP.from_message(resp)} do
        {{:remote, :update, _} = offer, %SDP{} = sdp} -> {offer, {:local, :update, sdp}}
        {{:remote, :update, _}, nil} -> {nil, nil}
        {offer, _} -> {offer, invite.sdp_answer}
      end

    invite = %{invite | sdp_offer: offer, sdp_answer: answer}
    Call.Dialog.update({:update, :uas, req, resp}, %{dialog | invite: invite}, call)
  end

  defp do_response(:update, code, _req, _resp, %Dialog{invite: %Invite{} = invite} = dialog, call)
       when code >= 300 do
    case invite.sdp_offer do
      {:remote, :update, _} ->
        Call.Dialog.store(%{dialog | invite: %{invite | sdp_offer: nil, sdp_answer: nil}}, call)

      _ ->
        Call.Dialog.store(dialog, call)
    end
  end

  # Responses to SUBSCRIBE, REFER and NOTIFY update their subscription, and
  # the dialog if 2xx
  defp do_response(method, code, req, resp, dialog, call)
       when method in [:subscribe, :notify, :refer] do
    dialog = Event.uas_response(req, resp, dialog, call)
    type = if method == :notify, do: :notify, else: :subscribe

    if code in 200..299,
      do: Call.Dialog.update({type, :uas, req, resp}, dialog, call),
      else: Call.Dialog.store(dialog, call)
  end

  defp do_response(_method, _code, _req, _resp, dialog, call), do: Call.Dialog.store(dialog, call)

  defp invite_answer(code, req, resp, %Invite{sdp_offer: offer, sdp_answer: answer}) do
    case {offer, SDP.from_message(resp)} do
      {{:remote, :invite, _}, %SDP{} = sdp} ->
        {offer, {:local, :invite, sdp}}

      {{:remote, :invite, _}, nil} when code >= 200 ->
        {nil, nil}

      {nil, %SDP{} = sdp} ->
        # With an offer in the INVITE, the exchange was completed in a
        # provisional response: this is a new answer to the same offer
        case SDP.from_message(req) do
          nil -> {{:local, :invite, sdp}, nil}
          req_sdp -> {{:remote, :invite, req_sdp}, {:local, :invite, sdp}}
        end

      {{:local, :invite, _}, %SDP{} = sdp} ->
        {{:local, :invite, sdp}, nil}

      _ ->
        {offer, answer}
    end
  end
end
