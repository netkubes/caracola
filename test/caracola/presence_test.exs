defmodule Caracola.PresenceTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Notifier, Presence, Subscription, UAC}
  alias Caracola.Test.{Client, PresServer}

  import Caracola.Test.Helpers

  doctest Presence
  doctest Notifier

  setup do
    port = start_service(PresServer)
    start_service(Client)
    Caracola.EventCompositor.clear(PresServer)
    %{alice: "sip:alice@127.0.0.1:#{port}", aor: {:sip, "alice", "127.0.0.1"}}
  end

  defp next_notify do
    assert_receive {Client, {:notify, body}}, 2000
    assert {:ok, doc} = Presence.decode(body)
    doc
  end

  defp tuples(doc), do: Map.new(doc.tuples, &{&1.id, &1.status})

  defp publish(uri, tuples) do
    opts = [
      event: "presence",
      content_type: Presence.content_type(),
      body: Presence.encode("sip:alice@127.0.0.1", tuples)
    ]

    assert {:ok, 200, meta} = UAC.publish(Client, uri, opts)
    meta[:sip_etag]
  end

  test "publications are composed and notified", %{alice: alice, aor: aor} do
    assert {:ok, 200, [subscription: subs]} =
             UAC.subscribe(Client, alice, event: "presence", expires: 60)

    # Without publications: closed
    assert %{entity: "sip:alice@127.0.0.1", tuples: [%{id: "default", status: :closed}]} =
             next_notify()

    assert [_] = Notifier.watchers(PresServer, "Presence", aor)
    assert {:ok, %Subscription{status: :active}} = Subscription.get(subs)

    # A publication is sent as it is
    pc = publish(alice, [%{id: "pc", status: :open, note: "Online"}])
    assert %{tuples: [%{id: "pc", status: :open, note: "Online"}]} = next_notify()

    # Two are composed
    publish(alice, [%{id: "phone", status: :closed}])
    assert tuples(next_notify()) == %{"pc" => :open, "phone" => :closed}

    # Modification and removal of the first one
    body = Presence.encode("sip:alice@127.0.0.1", [%{id: "pc", status: :closed}])

    assert {:ok, 200, _} =
             UAC.publish(Client, alice,
               event: "presence",
               sip_if_match: pc,
               content_type: Presence.content_type(),
               body: body
             )

    assert tuples(next_notify()) == %{"pc" => :closed, "phone" => :closed}

    assert {:ok, 200, _} =
             UAC.publish(Client, alice, event: "presence", sip_if_match: pc, expires: 0)

    assert tuples(next_notify()) == %{"phone" => :closed}

    # A refresh gets the state, and the end of the subscription a last one
    assert {:ok, 200, [subscription: ^subs]} = UAC.subscribe(subs, expires: 60)
    assert tuples(next_notify()) == %{"phone" => :closed}
    assert {:ok, 200, [subscription: ^subs]} = UAC.subscribe(subs, expires: 0)
    assert tuples(next_notify()) == %{"phone" => :closed}
    eventually(fn -> Notifier.watchers(PresServer, "presence", aor) == [] end)
  end

  test "authorization and other events", %{alice: alice} do
    assert {:ok, 403, []} =
             UAC.subscribe(Client, alice, event: "presence", from: "<sip:eve@127.0.0.1>")

    assert {:ok, 489, []} = UAC.subscribe(Client, alice, event: "other")
    refute_received {Client, {:notify, _}}
  end

  test "pidf" do
    assert Presence.decode("<presence/>") == {:ok, %{entity: nil, tuples: [], notes: []}}
    assert Presence.decode("<other/>") == :error
    assert Presence.decode("<presence") == :error

    # Prefixes and other namespaces
    body = """
    <?xml version="1.0"?>
    <p:presence xmlns:p="urn:ietf:params:xml:ns:pidf" xmlns:r="urn:ietf:params:xml:ns:pidf:rpid" entity="sip:a@b">
      <p:tuple id="t&amp;1">
        <p:status><p:basic> open </p:basic></p:status>
        <p:contact priority="0.5">sip:a@192.0.2.1</p:contact>
        <p:timestamp>2026-10-26T10:00:00Z</p:timestamp>
      </p:tuple>
      <r:person id="p1"><r:activities><r:busy/></r:activities></r:person>
      <p:note>Away &lt;5m&gt;</p:note>
    </p:presence>
    """

    assert {:ok,
            %{
              entity: "sip:a@b",
              notes: ["Away <5m>"],
              tuples: [
                %{
                  id: "t&1",
                  status: :open,
                  contact: "sip:a@192.0.2.1",
                  priority: "0.5",
                  timestamp: "2026-10-26T10:00:00Z"
                } = tuple
              ]
            } = doc} = Presence.decode(body)

    # Encoded and decoded back
    assert Presence.decode(Presence.encode("sip:a@b", [tuple], notes: doc.notes)) == {:ok, doc}

    # No DTDs (entity expansion)
    dtd = ~s(<?xml version="1.0"?><!DOCTYPE p [<!ENTITY a "aaaa">]><presence entity="&a;"/>)
    assert Presence.decode(dtd) == :error
  end
end
