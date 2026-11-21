defmodule Caracola.CallTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Call, Dialog, Message, UAC}
  alias Caracola.Test.{Client, Server}

  import Caracola.Test.Helpers

  # Ported and adapted from NkSIP's t03_uac and t04_uas

  test "options over udp and tcp" do
    port = start()

    assert {:ok, 200, [{:reason_phrase, "OK"}, {"allow", [allow]}, {:call_id, call_id}]} =
             UAC.options(Client, "sip:127.0.0.1:#{port}",
               get_meta: [:reason_phrase, "allow", :call_id]
             )

    assert allow =~ "INVITE"
    assert_receive {Server, {:route, :options}}

    assert {:ok, 200, [call_id: tcp_call_id]} =
             UAC.options(Client, "<sip:127.0.0.1:#{port};transport=tcp>", get_meta: [:call_id])

    # TCP transactions finish at once; UDP ones wait for timers J and K
    eventually(fn ->
      Call.find(Server, tcp_call_id) == nil and Call.find(Client, tcp_call_id) == nil
    end)

    assert Call.find(Server, call_id) != nil
  end

  test "errors before sending" do
    port = start()
    uri = "sip:127.0.0.1:#{port}"

    assert UAC.options(Client, "sip::a") == {:error, :invalid_uri}
    assert UAC.options(Client, uri, from: "<>") == {:error, {:invalid, "from"}}
    assert UAC.options(Client, uri, to: "<>") == {:error, {:invalid, "to"}}
    assert UAC.options(Client, uri, route: "<>") == {:error, {:invalid, "route"}}
    assert UAC.options(Client, uri, contact: "<>") == {:error, {:invalid, "contact"}}
    assert UAC.options(Client, uri, cseq_num: -1) == {:error, {:invalid_config, :cseq_num}}
    assert UAC.options(Client, uri, [:unknown]) == {:error, {:invalid_config, :unknown}}
    assert UAC.options(Caracola.Test.Unknown, uri) == {:error, :service_not_started}
  end

  test "connection errors, sync and async" do
    start()
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, closed} = :inet.port(socket)
    :gen_tcp.close(socket)
    uri = "<sip:127.0.0.1:#{closed};transport=tcp>"

    assert UAC.options(Client, uri) == {:error, :service_unavailable}

    assert {:async, {Client, _, _}} = UAC.options(Client, uri, [:async, callback: callback()])
    assert_receive {:callback, {:error, :service_unavailable}}
  end

  test "invite with provisional responses, sync and async" do
    port = start()
    uri = "sip:127.0.0.1:#{port}"
    headers = [{:add, "x-op", "busy"}, {:add, "x-prov", "true"}]

    assert {:ok, 486, [call_id: call_id]} =
             UAC.invite(
               Client,
               uri,
               [:get_request, callback: callback(), get_meta: [:call_id]] ++ headers
             )

    assert_receive {:callback, {:req, %Message{class: {:req, :invite}, call_id: ^call_id}}}
    assert_receive {:callback, {:resp, 180, %Message{call_id: ^call_id}}}
    refute_received {:callback, {:resp, 486, _}}

    assert {:async, {Client, call_id, _}} =
             UAC.invite(Client, uri, [:async, callback: callback()] ++ headers)

    assert_receive {:callback, {:resp, 180, %Message{call_id: ^call_id}}}
    assert_receive {:callback, {:resp, 486, %Message{call_id: ^call_id}}}

    # The ACK for the 486 is absorbed by the INVITE transaction
    refute_receive {Server, {:route, :ack}}, 100
  end

  test "message" do
    port = start()

    assert {:ok, 200, []} =
             UAC.message(Client, "sip:user@127.0.0.1:#{port}", [
               :date,
               expires: 10,
               content_type: "text/plain",
               body: "Message"
             ])

    assert_receive {Server, {:message, req}}
    assert %Message{expires: 10, content_type: {"text/plain", []}, body: "Message"} = req
    assert [date] = Message.header(req, "date")
    assert {:ok, date} = Caracola.Date.parse(date)
    assert DateTime.diff(DateTime.utc_now(), date) < 2
    assert req.from.user == "client"
  end

  test "loop detection and stateless replies" do
    port = start()
    uri = "sip:127.0.0.1:#{port}"
    stateful = {:add, "x-op", "reply-stateful"}

    assert {:ok, 200, [call_id: call_id, from: from, cseq_num: cseq]} =
             UAC.options(Client, uri, [stateful, get_meta: [:call_id, :from, :cseq_num]])

    # Same From tag, CSeq and method, different branch
    assert {:ok, 482, [reason_phrase: "Loop Detected"]} =
             UAC.options(Client, uri, [
               stateful,
               call_id: call_id,
               from: from,
               cseq_num: cseq,
               get_meta: [:reason_phrase]
             ])

    # Stateless replies leave no transaction, so loops are not detected
    stateless = {:add, "x-op", "reply-stateless"}

    assert {:ok, 200, [call_id: call_id, from: from, cseq_num: cseq]} =
             UAC.options(Client, uri, [stateless, get_meta: [:call_id, :from, :cseq_num]])

    assert {:ok, 200, []} =
             UAC.options(Client, uri, [stateless, call_id: call_id, from: from, cseq_num: cseq])
  end

  test "unsupported extensions and invalid replies" do
    port = start()
    uri = "sip:127.0.0.1:#{port}"

    # "a" is supported by the server
    assert {:ok, 420, [{"unsupported", ["b,d"]}]} =
             UAC.options(Client, uri, [{:add, "require", "a,b;c,d"}, get_meta: ["unsupported"]])

    assert {:ok, 500, [reason_phrase: "Invalid Service Response"]} =
             UAC.options(Client, uri, [
               {:add, "x-op", "reply-invalid"},
               get_meta: [:reason_phrase]
             ])

    assert {:ok, 405, [{"allow", [_]}]} = UAC.request(Client, "FOO", uri, get_meta: ["allow"])
    assert {:ok, 481, []} = UAC.request(Client, :bye, uri)
    assert {:ok, 603, []} = UAC.invite(Client, uri)
  end

  test "uac timeouts" do
    start([], timer_t1: 10)
    # A socket that never replies
    {:ok, socket} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)

    assert {:ok, 408, [reason_phrase: "Timer F Timeout"]} =
             UAC.options(Client, "sip:127.0.0.1:#{port}", get_meta: [:reason_phrase])

    assert {:ok, 408, [reason_phrase: "Timer B Timeout"]} =
             UAC.invite(Client, "sip:127.0.0.1:#{port}", get_meta: [:reason_phrase])

    # Requests were retransmitted (timers A and E)
    assert {:ok, {_, _, "OPTIONS " <> _}} = :gen_udp.recv(socket, 0, 100)
    assert {:ok, {_, _, "OPTIONS " <> _}} = :gen_udp.recv(socket, 0, 100)
  end

  test "uas timeouts" do
    port = start(timer_t1: 10, timer_c: 1)
    uri = "<sip:127.0.0.1:#{port};transport=tcp>"

    assert {:ok, 408, [reason_phrase: "No-INVITE Timeout"]} =
             UAC.options(Client, uri, [{:add, "x-sleep", "2000"}, get_meta: [:reason_phrase]])

    assert {:ok, 408, [reason_phrase: "Timer C Timeout"]} =
             UAC.invite(Client, uri, [
               {:add, "x-op", "busy"},
               {:add, "x-sleep", "2000"},
               get_meta: [:reason_phrase]
             ])
  end

  test "cancel" do
    port = start()
    headers = [{:add, "x-op", "busy"}, {:add, "x-prov", "true"}, {:add, "x-sleep", "2000"}]

    assert {:async, handle} =
             UAC.invite(
               Client,
               "sip:127.0.0.1:#{port}",
               [:async, callback: callback()] ++ headers
             )

    {_, call_id, _} = handle
    assert_receive {:callback, {:resp, 180, _}}
    assert UAC.cancel(handle) == :ok
    assert_receive {:callback, {:resp, 487, _}}
    assert_receive {Server, {:cancel, ^call_id}}
  end

  test "max calls" do
    port = start([], max_calls: 1)
    headers = [{:add, "x-op", "busy"}, {:add, "x-sleep", "500"}]

    assert {:async, _} =
             UAC.invite(
               Client,
               "sip:127.0.0.1:#{port}",
               [:async, callback: callback()] ++ headers
             )

    assert UAC.options(Client, "sip:127.0.0.1:#{port}") == {:error, :too_many_calls}
    assert_receive {:callback, {:resp, 486, _}}
  end

  test "large requests are sent over tcp" do
    port = start()
    body = String.duplicate("x", 2000)
    assert {:ok, 200, []} = UAC.message(Client, "sip:127.0.0.1:#{port}", body: body)
    assert_receive {Server, {:message, %Message{body: ^body, port: %{transport: :tcp}}}}
  end

  test "retransmissions are absorbed" do
    port = start()
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    request =
      "OPTIONS sip:127.0.0.1 SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP 127.0.0.1;branch=z9hG4bKretrans\r\n" <>
        "From: <sip:a@a>;tag=1\r\nTo: <sip:b@b>\r\nCall-ID: retrans\r\nCSeq: 1 OPTIONS\r\n" <>
        "Content-Length: 0\r\n\r\n"

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, request)

    assert {:ok, {_, ^port, "SIP/2.0 200 OK\r\n" <> _ = response}} =
             :gen_udp.recv(socket, 0, 1000)

    # rport and received are added to the Via of the response (RFC 3581)
    assert response =~ ";received=127.0.0.1"

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, request)
    assert {:ok, {_, ^port, ^response}} = :gen_udp.recv(socket, 0, 1000)

    assert_receive {Server, {:route, :options}}
    refute_receive {Server, {:route, :options}}, 100
  end

  # Runs the expiration check in the process of a call, with the clock
  # moved forward
  defp check_call(service, call_id, shift) do
    pid = Call.find(service, call_id)
    :sys.replace_state(pid, &Call.check_call(&1, shift))
    # Any message makes it stop if nothing is left
    send(pid, :wake_up)
  end

  test "expired transactions and dialogs" do
    port = start()
    uri = "sip:127.0.0.1:#{port}"
    call_id = "expire-#{System.unique_integer([:positive])}"

    # The server does not answer in a minute
    task =
      Task.async(fn ->
        UAC.options(Client, uri, [{:add, "x-sleep", "60000"}, call_id: call_id])
      end)

    eventually(fn -> Call.find(Server, call_id) != nil end)

    # Not yet expired (2 * trans_timeout, 1800 seconds by default)
    check_call(Client, call_id, 1000)
    check_call(Server, call_id, 1000)
    assert Task.yield(task, 100) == nil

    # The caller gets an error, and the calls stop
    check_call(Client, call_id, 2000)
    assert Task.await(task) == {:error, :timeout}
    check_call(Server, call_id, 2000)
    eventually(fn -> Call.find(Client, call_id) == nil and Call.find(Server, call_id) == nil end)

    # A dialog without activity for 2 * dialog_timeout (3600 seconds)
    assert {:ok, 200, [dialog: {:dialog, _, call_id, _}]} =
             UAC.invite(Client, uri, [:auto_2xx_ack, {:add, "x-op", "ok"}])

    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    check_call(Server, call_id, 3000)
    assert [_] = Dialog.list(Server, call_id)
    check_call(Server, call_id, 4000)
    assert_receive {Server, {:dialog, {:invite_status, {:stop, :timeout}}}}
    eventually(fn -> Call.find(Server, call_id) == nil end)
  end
end
