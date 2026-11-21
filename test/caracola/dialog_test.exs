defmodule Caracola.DialogTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Message, SDP, UAC}
  alias Caracola.Dialog.Invite
  alias Caracola.Test.{Client, Server}

  import Caracola.Test.Helpers

  # Ported and adapted from NkSIP's t09_invite and t12_update

  @answer {:add, "x-op", "answer"}
  @increment {:add, "x-op", "increment"}

  defp sdp, do: SDP.new("client", [{"test", 1234, [{:rtpmap, 0, "codec1"}]}])

  # The dialog of the other side
  defp remote({:dialog, _, call_id, _}, service) do
    [dialog] = Dialog.list(service, call_id)
    dialog
  end

  defp get(dialog) do
    {:ok, dialog} = Dialog.get(dialog)
    dialog
  end

  defp call_id({:dialog, _, call_id, _}), do: call_id

  test "dialog" do
    port = start()
    sdp = sdp()

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Client, "sip:ok@127.0.0.1:#{port}", [@answer, body: sdp])

    assert UAC.ack(dia) == :ok
    assert_receive {Server, {:route, :ack}}
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    assert_receive {Server, {:session, {:start, server_local, server_remote}}}
    assert_receive {Client, {:session, {:start, ^server_remote, ^server_local}}}

    now = System.os_time(:second)

    assert %Dialog{
             invite: %Invite{status: :confirmed, answered: answered} = invite,
             route_set: [],
             early: false,
             secure: false,
             local_seq: cseq,
             remote_seq: 0
           } = a = get(dia)

    assert now - a.created < 2 and now - a.updated < 2 and now - answered < 2
    assert invite.local_sdp == sdp
    assert %SDP{connect: {_, _, "Caracola.Test.Server"}, medias: [%{port: 4321}]} = server_local
    assert invite.remote_sdp == server_local
    assert to_string(a.remote_target) == "<sip:ok@127.0.0.1:#{port}>"
    assert to_string(a.local_target) == "<sip:client@127.0.0.1:#{port(Client)}>"

    dib = remote(dia, Server)
    b = get(dib)
    assert %Dialog{invite: %Invite{status: :confirmed}, local_seq: 0, remote_seq: ^cseq} = b
    assert {b.invite.local_sdp, b.invite.remote_sdp} == {server_local, sdp}
    assert b.remote_target == a.local_target and b.local_target == a.remote_target

    # In-dialog OPTIONS: the local CSeq is incremented
    assert {:ok, 200, [cseq_num: cseq2]} = UAC.options(dia, get_meta: [:cseq_num])
    assert cseq2 == cseq + 1
    assert get(dia).remote_seq == 0
    assert %Dialog{local_seq: 0, remote_seq: ^cseq2} = get(dib)

    # From the remote party, forcing the CSeq
    assert {:ok, 200, []} = UAC.options(dib, cseq_num: 9999)
    assert %Dialog{local_seq: ^cseq2, remote_seq: 9999} = get(dia)
    assert get(dib).local_seq == 9999

    assert {:ok, 500, [reason_phrase: "Old CSeq in Dialog"]} =
             UAC.options(dib, cseq_num: 9998, get_meta: [:reason_phrase])

    # INVITE in the opposite direction, the offer comes in the 200 and the
    # ACK does not answer it
    assert {:ok, 200, [dialog: ^dib]} = UAC.invite(dib, [@answer])
    assert UAC.ack(dib) == :ok
    assert_receive {Client, {:route, :ack}}
    assert_receive {Client, {:dialog, {:invite_status, :confirmed}}}
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    assert get(dib).invite.local_sdp == server_local

    assert {:ok, 200, []} = UAC.bye(dia)
    assert_receive {Server, {:route, :bye}}
    assert_receive {Server, {:dialog, {:invite_status, {:stop, :caller_bye}}}}
    assert_receive {Client, {:dialog, {:invite_status, {:stop, :caller_bye}}}}
    assert_receive {Server, {:session, :stop}}
    assert_receive {Client, {:session, :stop}}
    assert_receive {Server, {:dialog, :stop}}
    assert_receive {Client, {:dialog, :stop}}
    assert Dialog.list(Client, call_id(dia)) == []
    assert Dialog.get(dia) == {:error, :unknown_dialog}
    assert UAC.bye(dia) == {:error, :unknown_dialog}
  end

  test "route set and re-INVITE" do
    port = start()
    cport = port(Client)
    sdp = sdp()

    # Record-Route as inserted by two proxies, the closest to the server first
    rr = ["<sip:127.0.0.1:#{cport};lr>", "<sip:127.0.0.1:#{port};lr>"]
    headers = [@answer, {:add, "record-route", Enum.join(rr, ", ")}]

    # The response copies the Record-Route
    assert {:ok, 200, [{:dialog, dia}, {"record-route", [rr_header]}]} =
             UAC.invite(
               Client,
               "sip:ok@127.0.0.1:#{port}",
               [body: sdp, get_meta: ["record-route"]] ++ headers
             )

    assert rr_header == Enum.join(rr, ", ")

    # Route set of the UAC: the reversed Record-Route
    assert :ok = UAC.ack(dia, [:get_request, callback: callback()])
    assert_receive {:callback, {:req, ack}}
    assert Enum.map(ack.routes, &to_string/1) == Enum.reverse(rr)
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    assert_receive {Server, {:session, {:start, server_local, _}}}

    dib = remote(dia, Server)
    assert Enum.map(get(dib).route_set, &to_string/1) == rr
    assert Enum.map(get(dia).route_set, &to_string/1) == Enum.reverse(rr)

    # re-INVITE updating the SDP, the route set does not change
    sdp2 = SDP.update(sdp, :sendonly)

    assert {:ok, 200, [dialog: ^dia]} =
             UAC.invite(dia, [@increment, {:add, "record-route", "<sip:other>"}, body: sdp2])

    assert :ok = UAC.ack(dia)
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    assert_receive {Server, {:session, {:update, server_local2, ^sdp2}}}
    assert_receive {Client, {:session, {:update, ^sdp2, ^server_local2}}}
    assert server_local2.vsn == server_local.vsn + 1
    assert Enum.map(get(dib).route_set, &to_string/1) == rr
    assert Enum.map(get(dia).route_set, &to_string/1) == Enum.reverse(rr)

    # re-INVITE from the other party
    assert {:ok, 200, [dialog: ^dib]} = UAC.invite(dib, [@increment, body: server_local2])
    assert :ok = UAC.ack(dib)
    assert_receive {Client, {:session, {:update, sdp3, ^server_local2}}}
    assert sdp3.vsn == sdp2.vsn + 1
    assert get(dib).invite.remote_sdp == sdp3

    # BYE from the callee follows the route set
    assert {:ok, 200, []} = UAC.bye(dib, [:get_request, callback: callback()])
    assert_receive {:callback, {:req, bye}}
    assert Enum.map(bye.routes, &to_string/1) == rr
    assert_receive {Server, {:dialog, {:invite_status, {:stop, :callee_bye}}}}
    assert_receive {Client, {:dialog, {:invite_status, {:stop, :callee_bye}}}}
  end

  test "requests pending" do
    port = start()
    uri = "<sip:ok@127.0.0.1:#{port};transport=tcp>"

    # Without the ACK the dialog stays accepted
    assert {:ok, 200, [dialog: dia]} = UAC.invite(Client, uri, [@answer])
    assert get(dia).invite.status == :accepted_uac
    assert UAC.invite(dia) == {:error, :request_pending}
    assert UAC.ack(dia) == :ok
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    dib = remote(dia, Server)

    # A new INVITE while the server processes another one
    assert {:async, _} =
             UAC.invite(dia, [:async, {:add, "x-sleep", "300"}, @answer, callback: callback()])

    assert UAC.invite(dia) == {:error, :request_pending}

    assert {:ok, 500, [{:reason_phrase, "Processing Previous INVITE"}, {"retry-after", [_]}]} =
             UAC.invite(dia, [:no_dialog, get_meta: [:reason_phrase, "retry-after"]])

    assert_receive {:callback, {:resp, 200, resp}}
    assert Dialog.handle(resp) == dia
    assert UAC.ack(dia) == :ok
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}

    # Glare: both parties send a re-INVITE
    headers = [{:add, "x-prov", "true"}, {:add, "x-sleep", "300"}, @answer]
    assert {:async, _} = UAC.invite(dib, [:async, callback: callback()] ++ headers)

    assert_receive {:callback, {:resp, 180, _}}
    assert {:ok, 491, []} = UAC.invite(dia, [:no_dialog])
    assert_receive {:callback, {:resp, 200, _}}
    assert UAC.ack(dib) == :ok
    assert_receive {Client, {:route, :ack}}

    assert {:ok, 200, []} = UAC.bye(dia)
    assert_receive {Server, {:dialog, :stop}}
  end

  test "update" do
    port = start()
    sdp = sdp()

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Client, "sip:ok@127.0.0.1:#{port}", [@answer, body: sdp])

    assert UAC.ack(dia) == :ok
    assert_receive {Server, {:session, {:start, server_local, _}}}
    dib = remote(dia, Server)

    # Offer in UPDATE, answer in its response
    sdp2 = SDP.increment(sdp)
    assert {:ok, 200, []} = UAC.update(dia, [@increment, body: sdp2])
    assert_receive {Server, {:session, {:update, server_local2, ^sdp2}}}
    assert_receive {Client, {:session, {:update, ^sdp2, ^server_local2}}}
    assert server_local2.vsn == server_local.vsn + 1

    # UPDATE changing the remote target
    target = "<sip:b@127.0.0.1:#{port}>"
    server_local3 = SDP.increment(server_local2)
    assert {:ok, 200, []} = UAC.update(dib, [@increment, body: server_local3, contact: target])
    assert_receive {Client, {:dialog, :target_update}}
    assert_receive {Client, {:session, {:update, sdp3, ^server_local3}}}
    assert sdp3.vsn == sdp2.vsn + 1
    assert to_string(get(dia).remote_target) == target
    assert to_string(get(dib).local_target) == target
    assert get(dib).invite.remote_sdp == sdp3

    # No UPDATE with an offer while another offer is pending
    headers = [@increment, {:add, "x-sleep", "300"}]

    assert {:async, _} =
             UAC.invite(dia, [:async, callback: callback(), body: SDP.increment(sdp3)] ++ headers)

    assert UAC.update(dia, body: SDP.increment(sdp3)) == {:error, :request_pending}
    assert_receive {:callback, {:resp, 200, _}}
    assert UAC.ack(dia) == :ok

    # The new target is used
    assert {:ok, 200, []} = UAC.bye(dia)
    assert_receive {Server, {:dialog, {:invite_status, {:stop, :caller_bye}}}}
  end

  test "auto ack and 2xx retransmission" do
    port = start(timer_t1: 10)

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Client, "sip:ok@127.0.0.1:#{port}", [@answer, :auto_2xx_ack])

    assert_receive {Server, {:route, :ack}}
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    assert {:ok, 200, []} = UAC.bye(dia)

    # Without ACK, the server retransmits the 200 and finally sends BYE
    assert {:ok, 200, [dialog: dia]} = UAC.invite(Client, "sip:ok@127.0.0.1:#{port}", [@answer])
    assert get(dia).invite.status == :accepted_uac
    assert_receive {Server, {:dialog, :invite_timeout}}
    assert_receive {Client, {:route, :bye}}
    assert_receive {Client, {:dialog, {:invite_status, {:stop, :callee_bye}}}}
    assert_receive {Server, {:dialog, {:invite_status, {:stop, :callee_bye}}}}
  end

  test "unknown dialogs" do
    port = start()
    assert UAC.bye({:dialog, Client, "unknown", "unknown"}) == {:error, :unknown_dialog}
    assert Dialog.get({:dialog, Client, "unknown", "unknown"}) == {:error, :unknown_dialog}

    # Requests with To tag must belong to a dialog, unless sent with :no_dialog
    uri = "sip:127.0.0.1:#{port}"
    to = "<sip:a@127.0.0.1>;tag=unknown"
    assert UAC.options(Client, uri, to: to) == {:error, :unknown_dialog}
    assert {:ok, 481, []} = UAC.options(Client, uri, [:no_dialog, to: to])

    # Early dialogs end with the final response
    assert {:ok, 486, []} =
             UAC.invite(Client, "sip:127.0.0.1:#{port}", [
               {:add, "x-op", "busy"},
               {:add, "x-prov", "true"}
             ])

    assert_receive {Client, {:dialog, :start}}
    assert_receive {Client, {:dialog, {:invite_status, {:stop, :busy}}}}
    refute_received {Client, {:dialog, :target_update}}
    assert_receive {Server, {:dialog, {:invite_status, {:stop, :busy}}}}
  end

  test "info and bye with reason" do
    port = start()

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Client, "sip:ok@127.0.0.1:#{port}", [@answer, :auto_2xx_ack])

    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    assert {:ok, 200, []} = UAC.info(dia, content_type: "text/plain", body: "info")
    assert_receive {Server, {:info, %Message{body: "info"} = info}}
    assert Dialog.handle(info) == remote(dia, Server)

    assert {:ok, 200, []} = UAC.bye(dia, reason: "SIP;cause=200;text=\"Call completed\"")
    assert_receive {Server, {:bye, bye}}
    assert Message.header(bye, "reason") == ["SIP;cause=200;text=\"Call completed\""]
  end

  test "handles of messages" do
    port = start()

    assert {:ok, 200, [dialog: dia, call_id: call_id]} =
             UAC.invite(Client, "sip:ok@127.0.0.1:#{port}", [@answer, get_meta: [:call_id]])

    assert call_id(dia) == call_id
    assert {:dialog, Client, ^call_id, _} = dia
    assert Dialog.handle(%Message{}) == nil
    assert UAC.ack(dia) == :ok
    assert {:ok, 200, []} = UAC.bye(dia)
  end
end
