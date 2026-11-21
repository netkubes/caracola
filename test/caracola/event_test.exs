defmodule Caracola.EventTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Message, Reply, Subscription, UAC, URI}
  alias Caracola.Test.{Client, Server}

  import Caracola.Test.Helpers

  # Ported and adapted from NkSIP's t14_event. Client supports myevent1-3
  # and Server myevent4; the expiration offset is 0.

  setup do
    sport = start_service(Server, sip: [events: "myevent4", event_expires_offset: 0])
    start_service(Client, sip: [events: "myevent1,myevent2,myevent3", event_expires_offset: 0])
    %{uri: "sip:127.0.0.1:#{sport}"}
  end

  defp get(handle) do
    {:ok, subs} = Subscription.get(handle)
    subs
  end

  # The subscription at the other side
  defp remote({:subscription, _, call_id, _, id}, service) do
    [dialog] = Dialog.list(service, call_id)
    {:ok, dialog} = Dialog.get(dialog)
    Subscription.handle(Subscription.find(dialog, id))
  end

  defp subscriptions(dialog) do
    {:ok, dialog} = Dialog.get(dialog)
    Enum.map(dialog.subscriptions, &Subscription.handle/1)
  end

  test "basic", %{uri: uri} do
    assert {:ok, 489, []} =
             UAC.subscribe(Client, uri, [
               :get_request,
               event: "myevent1;id=a",
               callback: callback()
             ])

    assert_receive {:callback, {:req, req}}
    assert {"myevent1", [{"id", "a"}]} = req.event

    assert {:ok, 200, [{:subscription, s1a}, {"event", ["myevent4;id=4;o=2"]}]} =
             UAC.subscribe(Client, uri,
               event: "myevent4;id=4;o=2",
               expires: 1,
               get_meta: ["event"]
             )

    s1b = remote(s1a, Server)
    event = {"myevent4", [{"id", "4"}, {"o", "2"}]}

    assert %Subscription{status: :init, event: ^event, class: :uac, answered: nil, expires: 1} =
             get(s1a)

    assert %Subscription{status: :init, event: ^event, class: :uas, answered: nil, expires: 1} =
             get(s1b)

    assert {:ok, %Dialog{invite: nil}} = Dialog.get(Subscription.dialog(s1a))
    assert subscriptions(Subscription.dialog(s1a)) == [s1a]

    # Without NOTIFY, it expires
    assert_receive {Server, {:dialog, {:subscription_status, :init, _}}}
    assert_receive {Server, {:dialog, {:subscription_status, :middle_timer, _}}}
    assert_receive {Server, {:dialog, {:subscription_status, {:terminated, :timeout}, _}}}, 2_000
    assert_receive {Client, {:dialog, {:subscription_status, {:terminated, :timeout}, _}}}, 2_000
    assert_receive {Client, {:dialog, :stop}}
    assert Subscription.get(s1a) == {:error, :unknown_dialog}

    assert {:ok, 200, [subscription: s2a]} =
             UAC.subscribe(Client, uri, event: "myevent4;id=4;o=2", expires: 2)

    s2b = remote(s2a, Server)

    assert {:ok, 200, []} = UAC.notify(s2b, subscription_state: :pending, body: "notify1")
    assert_receive {Server, {:dialog, {:subscription_status, :pending, _}}}
    assert_receive {Client, {:dialog, {:subscription_status, :pending, _}}}
    assert_receive {Client, {:notify, "notify1"}}

    assert {:ok, 200, []} = UAC.notify(s2b, body: "notify2")
    assert_receive {Server, {:dialog, {:subscription_status, :active, _}}}
    assert_receive {Client, {:dialog, {:subscription_status, :active, _}}}
    assert_receive {Client, {:notify, "notify2"}}
    assert %Subscription{status: :active, answered: answered} = get(s2a)
    assert is_integer(answered)

    assert {:ok, 200, []} = UAC.notify(s2b, subscription_state: {:terminated, :giveup, 5})
    assert_receive {Client, {:notify, ""}}
    assert_receive {Server, {:dialog, {:subscription_status, {:terminated, :giveup, 5}, _}}}
    assert_receive {Client, {:dialog, {:subscription_status, {:terminated, :giveup, 5}, _}}}

    # NOTIFY for an unknown subscription
    assert UAC.notify(s2b) == {:error, :unknown_dialog}
  end

  test "2xx without Event" do
    # As Asterisk: the subscription is identified by the Event of the request
    {:ok, socket} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    task = Task.async(fn -> UAC.subscribe(Client, "sip:127.0.0.1:#{port}", event: "myevent1") end)
    {:ok, {ip, rport, data}} = :gen_udp.recv(socket, 0, 2000)
    {:ok, req, _} = Caracola.Parser.parse(data, :udp)

    resp =
      [
        "SIP/2.0 200 OK",
        for({"via", _} = h <- raw_headers(data), do: "Via: " <> elem(h, 1)),
        "From: " <> raw_header(data, "from"),
        "To: " <> raw_header(data, "to") <> ";tag=srv",
        "Call-ID: " <> req.call_id,
        "CSeq: #{elem(req.cseq, 0)} SUBSCRIBE",
        "Contact: <sip:127.0.0.1:#{port}>",
        "Expires: 60",
        "Content-Length: 0",
        "",
        ""
      ]
      |> List.flatten()
      |> Enum.join("\r\n")

    :ok = :gen_udp.send(socket, ip, rport, resp)
    assert {:ok, 200, [subscription: subs]} = Task.await(task)
    assert {:ok, %Subscription{event: {"myevent1", []}}} = Subscription.get(subs)
    :gen_udp.close(socket)
  end

  defp raw_headers(data) do
    for line <- String.split(data, "\r\n"),
        [name, value] <- [String.split(line, ":", parts: 2)],
        do: {String.downcase(name), String.trim(value)}
  end

  defp raw_header(data, name), do: data |> raw_headers() |> List.keyfind(name, 0) |> elem(1)

  test "unsolicited notify", %{uri: uri} do
    opts = [
      {:add, "subscription-state", "active"},
      event: "message-summary",
      body: "Messages-Waiting: yes\r\n"
    ]

    # RFC 6665: rejected by default
    assert {:ok, 481, []} = UAC.notify(Client, uri, opts)
    assert_receive {Server, {:unsolicited_notify, "Messages-Waiting: yes\r\n"}}

    # Accepted by the service, without dialogs
    assert {:ok, 200, []} = UAC.notify(Client, uri, [{:add, "x-op", "ok"} | opts])
    assert_receive {Server, {:unsolicited_notify, _}}
    refute_received {Server, {:dialog, :start}}
  end

  test "refresh", %{uri: uri} do
    opts = [{:add, "x-op", "expires-2"}, event: "myevent4", expires: 5]
    assert {:ok, 200, [subscription: s1a]} = UAC.subscribe(Client, uri, opts)
    s1b = remote(s1a, Server)
    assert {:ok, 200, []} = UAC.notify(s1b)

    # The response has changed the expiration to 2 seconds
    assert get(s1a).expires == 2
    assert get(s1b).expires == 2
    assert_receive {Server, {:dialog, {:subscription_status, :active, _}}}

    # Refresh, changing the expiration to 20 seconds
    assert {:ok, 200, [subscription: ^s1a]} = UAC.subscribe(s1a, expires: 20)
    assert get(s1a).expires == 20
    assert get(s1b).expires == 20

    assert {:ok, 200, []} = UAC.notify(s1b, subscription_state: {:terminated, :giveup})
    assert_receive {Server, {:dialog, {:subscription_status, {:terminated, :giveup}, _}}}

    # A refresh with expiration 0 ends the subscription with the next NOTIFY,
    # which is terminated;reason=timeout
    assert {:ok, 200, [subscription: s2a]} = UAC.subscribe(Client, uri, opts)
    s2b = remote(s2a, Server)
    assert {:ok, 200, []} = UAC.notify(s2b)
    assert {:ok, 200, [subscription: ^s2a]} = UAC.subscribe(s2a, expires: 0)
    assert {:ok, 200, []} = UAC.notify(s2b)
    assert_receive {Server, {:dialog, {:subscription_status, {:terminated, :timeout}, _}}}
    assert_receive {Client, {:dialog, {:subscription_status, {:terminated, :timeout}, _}}}
  end

  test "dialog", %{uri: uri} do
    sport = port(Server)
    cport = port(Client)

    assert {:ok, 200, [subscription: s1a]} =
             UAC.subscribe(Client, uri,
               event: "myevent4;id=1",
               expires: 2,
               contact: "<sip:a@127.0.0.1:#{cport}>"
             )

    dia = Subscription.dialog(s1a)
    s1b = remote(s1a, Server)

    # The first NOTIFY fixes the route set
    rr = "<sip:b1@127.0.0.1:#{sport};lr>, <sip:b@b>, <sip:a2@127.0.0.1:#{cport};lr>"
    assert {:ok, 200, []} = UAC.notify(s1b, [{:add, "record-route", rr}])
    {:ok, a} = Dialog.get(dia)
    assert to_string(a.local_target) == "<sip:a@127.0.0.1:#{cport}>"
    assert to_string(a.remote_target) == "<sip:127.0.0.1:#{sport}>"
    assert to_string(URI.encode(a.route_set)) == rr

    # It does not change any more, but the remote target does
    contact = "<sip:b@127.0.0.1:#{sport}>"

    assert {:ok, 200, []} =
             UAC.notify(s1b, [{:add, "record-route", "<sip:b@b>"}, contact: contact])

    {:ok, a} = Dialog.get(dia)
    assert to_string(a.remote_target) == contact
    assert to_string(URI.encode(a.route_set)) == rr

    # Another subscription in the same dialog, updating the local target
    assert {:ok, 200, [subscription: s2a]} =
             UAC.subscribe(dia,
               event: "myevent4;id=2",
               expires: 2,
               contact: "<sip:a3@127.0.0.1:#{cport}>"
             )

    assert Subscription.dialog(s2a) == dia
    dib = Subscription.dialog(remote(s2a, Server))
    s2b = remote(s2a, Server)
    assert {:ok, 200, []} = UAC.notify(s2b, contact: "<sip:b2@127.0.0.1:#{sport}>")

    {:ok, a} = Dialog.get(dia)
    {:ok, b} = Dialog.get(dib)
    assert to_string(a.local_target) == "<sip:a3@127.0.0.1:#{cport}>"
    assert to_string(a.remote_target) == "<sip:b2@127.0.0.1:#{sport}>"
    assert {b.local_target, b.remote_target} == {a.remote_target, a.local_target}
    assert b.route_set == Enum.reverse(a.route_set)
    assert subscriptions(dia) == [s1a, s2a]

    # An INVITE in the same dialog
    assert {:ok, 200, [dialog: ^dib]} = UAC.invite(dib, [{:add, "x-op", "ok"}])
    assert UAC.ack(dib) == :ok
    assert_receive {Client, {:dialog, {:invite_status, :confirmed}}}

    # The client does not support myevent4
    assert {:ok, 489, []} = UAC.subscribe(dib, event: "myevent4")

    assert {:ok, 200, [subscription: s3b]} = UAC.subscribe(dib, event: "myevent1", expires: 1)
    assert {:ok, 200, []} = UAC.notify(remote(s3b, Client))
    assert length(subscriptions(dia)) == 3
    assert length(subscriptions(dib)) == 3

    # The subscriptions expire, the INVITE usage remains
    eventually(fn -> subscriptions(dia) == [] and subscriptions(dib) == [] end, 150)
    assert {:ok, %Dialog{invite: %{status: :confirmed}}} = Dialog.get(dia)

    assert {:ok, 200, []} = UAC.bye(dib)
    assert_receive {Client, {:dialog, :stop}}
    assert Dialog.get(dia) == {:error, :unknown_dialog}
  end

  # NOTIFY sent by the server before the 200 to the SUBSCRIBE
  defp early_notify(%Message{} = req, to_tag, cseq \\ 1) do
    {:ok, [from]} = URI.parse("<sip:server@127.0.0.1>;tag=#{to_tag}")

    UAC.notify(Server, "sip:127.0.0.1:#{port(Client)}", [
      :no_dialog,
      call_id: req.call_id,
      from: from,
      to: req.from,
      cseq_num: cseq,
      event: "myevent4",
      subscription_state: {:active, 5},
      contact: "<sip:127.0.0.1:#{port(Server)}>"
    ])
  end

  test "out of order", %{uri: uri} do
    opts = [{:add, "x-op", "wait"}, :async, event: "myevent4", expires: 2, callback: callback()]
    assert {:async, _} = UAC.subscribe(Client, uri, opts)
    assert_receive {Server, {:subscribe, req}}

    # The NOTIFY creates the dialog and subscription, with the To tag the
    # 200 response will have
    assert {:ok, 200, []} = early_notify(req, Reply.to_tag_candidate(req))
    assert_receive {Client, {:dialog, {:subscription_status, :active, _}}}
    assert_receive {:callback, {:resp, 200, resp}}, 2_000
    s1a = Subscription.handle_of(resp)
    assert %Subscription{status: :active} = get(s1a)

    # The server did not see the NOTIFY, its subscription expires
    assert_receive {Server, {:dialog, {:subscription_status, :init, _}}}
    assert_receive {Server, {:dialog, {:subscription_status, {:terminated, :timeout}, _}}}, 3_000

    # A NOTIFY with another To tag (our From tag) is rejected
    assert {:async, _} = UAC.subscribe(Client, uri, opts)
    assert_receive {Server, {:subscribe, req}}
    {:ok, [from]} = URI.parse("<sip:client@127.0.0.1>;tag=a")
    assert {:ok, 481, []} = early_notify(%{req | from: from}, "b")
  end

  test "fork", %{uri: uri} do
    opts = [{:add, "x-op", "wait"}, :async, event: "myevent4", expires: 2, callback: callback()]
    assert {:async, _} = UAC.subscribe(Client, uri, opts)
    assert_receive {Server, {:subscribe, req}}

    # Several NOTIFYs from different parties create several dialogs
    assert {:ok, 200, []} = early_notify(req, "a")
    assert {:ok, 200, []} = early_notify(req, "b")
    assert_receive {:callback, {:resp, 200, resp}}, 2_000
    s1b = remote(Subscription.handle_of(resp), Server)
    assert {:ok, 200, []} = UAC.notify(s1b)
    assert {:ok, 200, []} = early_notify(req, "c")

    dialogs = Dialog.list(Client, req.call_id)
    assert length(dialogs) == 4
    for dialog <- dialogs, do: assert([_] = subscriptions(dialog))

    assert {:ok, 200, []} = UAC.notify(s1b, subscription_state: {:terminated, :giveup})
  end
end
