defmodule Caracola.Call.DialogUAC do
  @moduledoc false
  # Dialogs on the client side: requests sent and responses received inside
  # a dialog, and generation of in-dialog requests. Port of NkSIP's
  # nksip_call_uac_dialog.
  #
  # Offer/answer (RFC 3264 and RFC 6337):
  #
  #   * An offer in the INVITE is answered in the first response with SDP
  #     (later ones repeat the answer). Without offer in the INVITE, the
  #     first response with SDP is the offer, answered in the ACK.
  #   * UPDATE can carry a new offer, answered in its 2xx response, when no
  #     other offer is pending.

  require Logger

  alias Caracola.{Call, Dialog, Message, SDP, Util}
  alias Caracola.Call.{Event, SessionTimer, Transp}
  alias Caracola.Dialog.Invite

  ## ===================================================================
  ## Requests
  ## ===================================================================

  @doc false
  # Checks before sending an in-dialog request
  def pre_request(%Message{class: {:req, :ack}}, _call), do: :ok

  def pre_request(%Message{class: {:req, method}} = req, call) do
    case Call.Dialog.find(req.dialog_id, call) do
      nil ->
        {:error, :unknown_dialog}

      %Dialog{invite: invite} when method in [:invite, :update, :bye, :prack] ->
        invite_pre_request(method, req, invite)

      %Dialog{} = dialog when method == :notify ->
        Event.uac_pre_request(req, dialog)

      %Dialog{} ->
        :ok
    end
  end

  defp invite_pre_request(:invite, _req, nil), do: :ok
  defp invite_pre_request(_method, _req, nil), do: {:error, :unknown_dialog}

  defp invite_pre_request(method, req, %Invite{status: status, sdp_offer: offer}) do
    offer? = SDP.from_message(req) != nil

    cond do
      method == :invite and status != :confirmed -> {:error, :request_pending}
      method in [:invite, :update] and offer? and offer != nil -> {:error, :request_pending}
      method == :prack and status != :proceeding_uac -> {:error, :request_pending}
      true -> :ok
    end
  end

  @doc false
  # An in-dialog request has been sent
  def request(%Message{class: {:req, :ack}} = req, call), do: ack(req, call)

  def request(%Message{class: {:req, method}, cseq: {cseq, _}} = req, call) do
    case Call.Dialog.find(req.dialog_id, call) do
      %Dialog{} = dialog ->
        dialog = if cseq > dialog.local_seq, do: %{dialog | local_seq: cseq}, else: dialog
        do_request(method, req, dialog, call)

      nil ->
        call
    end
  end

  defp do_request(:invite, req, %Dialog{invite: nil} = dialog, call),
    do: do_request(:invite, req, %{dialog | invite: %Invite{status: :confirmed}}, call)

  defp do_request(:invite, req, %Dialog{invite: invite} = dialog, call) do
    offer = if sdp = SDP.from_message(req), do: {:local, :invite, sdp}

    invite = %{
      invite
      | status: :proceeding_uac,
        class: :uac,
        request: req,
        response: nil,
        ack: nil,
        sdp_offer: offer,
        sdp_answer: nil
    }

    Call.Dialog.store(%{dialog | invite: invite}, call)
  end

  defp do_request(:bye, _req, %Dialog{invite: %Invite{}} = dialog, call),
    do: Call.Dialog.update({:invite, :bye}, dialog, call)

  # A PRACK can carry a new offer, or the answer to an offer in the response
  defp do_request(
         :prack,
         req,
         %Dialog{invite: %Invite{status: :proceeding_uac} = invite} = dialog,
         call
       ) do
    case {invite.sdp_offer, SDP.from_message(req)} do
      {nil, %SDP{} = sdp} ->
        Call.Dialog.store(%{dialog | invite: %{invite | sdp_offer: {:local, :prack, sdp}}}, call)

      {{:remote, :invite, _}, %SDP{} = sdp} ->
        invite = %{invite | sdp_answer: {:local, :prack, sdp}}
        Call.Dialog.update(:prack, %{dialog | invite: invite}, call)

      _ ->
        Call.Dialog.store(dialog, call)
    end
  end

  defp do_request(:update, req, %Dialog{invite: %Invite{sdp_offer: nil} = invite} = dialog, call) do
    case SDP.from_message(req) do
      nil ->
        Call.Dialog.store(dialog, call)

      sdp ->
        Call.Dialog.store(%{dialog | invite: %{invite | sdp_offer: {:local, :update, sdp}}}, call)
    end
  end

  defp do_request(_method, _req, dialog, call), do: Call.Dialog.store(dialog, call)

  # ACK for a 2xx response
  defp ack(%Message{cseq: {cseq, _}} = req, call) do
    case Call.Dialog.find(req.dialog_id, call) do
      %Dialog{
        invite: %Invite{status: :accepted_uac, request: %Message{cseq: {^cseq, _}}} = invite
      } =
          dialog ->
        sdp = SDP.from_message(req)

        {offer, answer} =
          case invite.sdp_offer do
            {:remote, :invite, _} when sdp != nil -> {invite.sdp_offer, {:local, :ack, sdp}}
            {:remote, :invite, _} -> {nil, nil}
            offer -> {offer, invite.sdp_answer}
          end

        invite = %{invite | ack: req, sdp_offer: offer, sdp_answer: answer}
        Call.Dialog.update({:invite, :confirmed}, %{dialog | invite: invite}, call)

      _ ->
        Logger.notice("ignoring ACK for unknown dialog or INVITE")
        call
    end
  end

  ## ===================================================================
  ## Responses
  ## ===================================================================

  @doc false
  def response(%Message{class: {:req, method}} = req, %Message{} = resp, call) do
    {:resp, code, _} = resp.class

    call =
      case Call.Dialog.find(resp.dialog_id, call) do
        %Dialog{} = dialog -> do_response(method, code, req, resp, dialog, call)
        nil -> new_dialog(method, code, req, resp, call)
      end

    if method == :invite and code >= 300, do: stop_early(req, call), else: call
  end

  defp new_dialog(:invite, code, req, resp, call) when code in 101..299 do
    dialog = Call.Dialog.create(:uac, req, resp, call)
    offer = if sdp = SDP.from_message(req), do: {:local, :invite, sdp}
    invite = %Invite{status: :proceeding_uac, class: :uac, request: req, sdp_offer: offer}

    do_response(
      :invite,
      code,
      req,
      resp,
      Call.Dialog.new_invite(dialog, invite, code, call),
      call
    )
  end

  defp new_dialog(method, code, req, resp, call)
       when method in [:subscribe, :refer] and code in 200..299 do
    dialog = Call.Dialog.create(:uac, req, resp, call)
    do_response(method, code, req, resp, dialog, call)
  end

  defp new_dialog(_method, _code, _req, _resp, call), do: call

  # A final non-2xx response ends the early dialogs of the INVITE, even if
  # it has a different To tag (RFC 3261 §12.3)
  defp stop_early(%Message{id: id}, call) do
    Enum.reduce(Map.values(call.dialogs), call, fn
      %Dialog{invite: %Invite{status: :proceeding_uac, request: %Message{id: ^id}}} = dialog,
      call ->
        Call.Dialog.stop(:timeout, dialog, call)

      _dialog, call ->
        call
    end)
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
         %Dialog{invite: %Invite{status: :proceeding_uac} = invite} = dialog,
         call
       )
       when code < 300 do
    {offer, answer} = invite_answer(code, req, resp, invite)
    invite = %{invite | response: resp, sdp_offer: offer, sdp_answer: answer}
    status = if code < 200, do: :proceeding_uac, else: :accepted_uac
    Call.Dialog.update({:invite, status}, %{dialog | invite: invite}, call)
  end

  defp do_response(
         :invite,
         code,
         _req,
         resp,
         %Dialog{invite: %Invite{status: :proceeding_uac} = invite} = dialog,
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

  # Retransmission of the 2xx response: the ACK is sent again
  defp do_response(
         :invite,
         code,
         _req,
         _resp,
         %Dialog{invite: %Invite{status: :accepted_uac}} = dialog,
         call
       )
       when code < 300 do
    case dialog.invite.ack do
      %Message{} = ack ->
        case Transp.resend_request(ack) do
          {:ok, _} ->
            Call.Dialog.store(dialog, call)

          {:error, error} ->
            Logger.notice("dialog #{dialog.id} could not resend ACK: #{inspect(error)}")
            Call.Dialog.update({:invite, {:stop, 503}}, dialog, call)
        end

      nil ->
        Call.Dialog.store(dialog, call)
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
      {{:local, :prack, _}, %SDP{} = sdp} ->
        invite = %{invite | sdp_answer: {:remote, :prack, sdp}}
        Call.Dialog.update(:prack, %{dialog | invite: invite}, call)

      {{:local, :prack, _}, nil} ->
        Call.Dialog.store(%{dialog | invite: %{invite | sdp_offer: nil, sdp_answer: nil}}, call)

      _ ->
        Call.Dialog.store(dialog, call)
    end
  end

  defp do_response(:prack, _code, _req, _resp, %Dialog{invite: %Invite{} = invite} = dialog, call) do
    case invite.sdp_offer do
      {:local, :prack, _} ->
        Call.Dialog.store(%{dialog | invite: %{invite | sdp_offer: nil, sdp_answer: nil}}, call)

      _ ->
        Call.Dialog.store(dialog, call)
    end
  end

  defp do_response(:update, code, req, resp, %Dialog{invite: %Invite{} = invite} = dialog, call)
       when code in 200..299 do
    {offer, answer} =
      case {invite.sdp_offer, SDP.from_message(resp)} do
        {{:local, :update, _} = offer, %SDP{} = sdp} -> {offer, {:remote, :update, sdp}}
        {{:local, :update, _}, nil} -> {nil, nil}
        {offer, _} -> {offer, invite.sdp_answer}
      end

    invite = %{invite | sdp_offer: offer, sdp_answer: answer}
    Call.Dialog.update({:update, :uac, req, resp}, %{dialog | invite: invite}, call)
  end

  defp do_response(:update, code, _req, _resp, %Dialog{invite: %Invite{} = invite} = dialog, call)
       when code >= 300 do
    case invite.sdp_offer do
      {:local, :update, _} ->
        Call.Dialog.store(%{dialog | invite: %{invite | sdp_offer: nil, sdp_answer: nil}}, call)

      _ ->
        Call.Dialog.store(dialog, call)
    end
  end

  # Responses to SUBSCRIBE, REFER and NOTIFY update their subscription, and
  # the dialog if 2xx
  defp do_response(method, code, req, resp, dialog, call)
       when method in [:subscribe, :notify, :refer] do
    dialog = Event.uac_response(req, resp, dialog, call)
    type = if method == :notify, do: :notify, else: :subscribe

    if code in 200..299,
      do: Call.Dialog.update({type, :uac, req, resp}, dialog, call),
      else: Call.Dialog.store(dialog, call)
  end

  defp do_response(_method, _code, _req, _resp, dialog, call), do: Call.Dialog.store(dialog, call)

  defp invite_answer(code, req, resp, %Invite{sdp_offer: offer, sdp_answer: answer}) do
    case {offer, SDP.from_message(resp)} do
      {{:local, :invite, _}, %SDP{} = sdp} ->
        {offer, {:remote, :invite, sdp}}

      {{:local, :invite, _}, nil} when code >= 200 ->
        {nil, nil}

      {nil, %SDP{} = sdp} ->
        # With an offer in the INVITE, the exchange was completed in a
        # provisional response: this is a new answer to the same offer
        case SDP.from_message(req) do
          nil -> {{:remote, :invite, sdp}, nil}
          req_sdp -> {{:local, :invite, req_sdp}, {:remote, :invite, sdp}}
        end

      {{:remote, :invite, _}, %SDP{} = sdp} ->
        {{:remote, :invite, sdp}, nil}

      _ ->
        {offer, answer}
    end
  end

  ## ===================================================================
  ## In-dialog requests
  ## ===================================================================

  @doc false
  # SDP offered by the other party in the INVITE transaction in progress
  def remote_offer(dialog_id, call) do
    case Call.Dialog.find(dialog_id, call) do
      %Dialog{invite: %Invite{sdp_offer: {:remote, :invite, sdp}}} -> sdp
      _ -> nil
    end
  end

  @doc false
  # CSeq for a request sent again (after a challenge): the next one of its
  # dialog, or the next to its own
  def next_cseq(%Message{cseq: {cseq, _}} = req, call) do
    case Call.Dialog.find(req.dialog_id, call) do
      %Dialog{local_seq: local_seq} = dialog ->
        next = max(local_seq, cseq) + 1
        {next, Call.Dialog.store(%{dialog | local_seq: next}, call)}

      nil ->
        {cseq + 1, call}
    end
  end

  @doc false
  # Generates the Request-URI and options for an in-dialog request
  def make(dialog_id, method, opts, call) do
    case Call.Dialog.find(dialog_id, call) do
      nil ->
        {:error, :unknown_dialog}

      %Dialog{invite: invite} when method == :ack and not is_struct(invite, Invite) ->
        {:error, :invalid_dialog}

      %Dialog{invite: %Invite{status: status}} when method == :ack and status != :accepted_uac ->
        {:error, :invalid_dialog}

      dialog ->
        with {:ok, opts} <- subscription_opts(method, opts, dialog, call),
             do: generate(method, opts, dialog, call)
    end
  end

  defp generate(method, opts, dialog, call) do
    {cseq, local_seq} = cseq(method, Util.opt(opts, :cseq_num), dialog)

    # The current session interval, unless given
    opts =
      if SessionTimer.enabled?(call.config) and not Util.opt?(opts, :session_expires),
        do: SessionTimer.dialog_opts(method, dialog) ++ opts,
        else: opts

    opts =
      auth_headers(method, dialog) ++
        [from: dialog.local_uri, to: dialog.remote_uri, cseq_num: cseq] ++
        [route: dialog.route_set] ++
        contact(opts, dialog) ++ Enum.reject(opts, &match?({:cseq_num, _}, &1))

    call = Call.Dialog.store(%{dialog | local_seq: local_seq}, call)
    {:ok, dialog.remote_target, opts, call}
  end

  # Requests for a subscription (`{:subscription, id}`)
  defp subscription_opts(method, opts, dialog, call) do
    case Util.opt(opts, :subscription) do
      nil ->
        {:ok, opts}

      id ->
        opts = Enum.reject(opts, &match?({:subscription, _}, &1))
        Event.request_opts(method, id, opts, dialog, call)
    end
  end

  # CSeq of the request and new local CSeq of the dialog
  defp cseq(:ack, _cseq, %Dialog{invite: %Invite{request: %Message{cseq: {cseq, _}}}} = dialog),
    do: {cseq, dialog.local_seq}

  defp cseq(_method, cseq, %Dialog{local_seq: local_seq}) when is_integer(cseq) and local_seq > 0,
    do: {cseq, local_seq}

  defp cseq(_method, cseq, _dialog) when is_integer(cseq), do: {cseq, cseq}

  defp cseq(_method, nil, %Dialog{local_seq: local_seq}) when local_seq > 0,
    do: {local_seq + 1, local_seq + 1}

  defp cseq(_method, nil, _dialog) do
    cseq = Util.next_cseq() + 1000
    {cseq, cseq}
  end

  # The ACK for a 2xx carries the same credentials as the INVITE
  defp auth_headers(:ack, %Dialog{invite: %Invite{request: req}}) do
    for {name, value} <- req.headers,
        name in ["authorization", "proxy-authorization"],
        do: {:add, name, value}
  end

  defp auth_headers(_method, _dialog), do: []

  defp contact(opts, %Dialog{local_target: target}) do
    if :contact in opts or Util.opt?(opts, :contact) or target == nil,
      do: [],
      else: [contact: target]
  end
end
