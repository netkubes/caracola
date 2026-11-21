defmodule Caracola.EventPackagesTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Conference, MessageWaiting, UAC}
  alias Caracola.Test.{Client, PresServer}

  import Caracola.Test.Helpers

  doctest MessageWaiting
  doctest Conference

  setup do
    port = start_service(PresServer)
    start_service(Client)
    %{port: port}
  end

  defp next_notify do
    assert_receive {Client, {:notify, body}}, 2000
    body
  end

  test "message waiting", %{port: port} do
    aor = {:sip, "alice", "127.0.0.1"}
    alice = "sip:alice@127.0.0.1:#{port}"

    assert {:ok, 200, [{:subscription, subs}, {"accept-event", _}]} =
             UAC.subscribe(Client, alice, event: "message-summary", get_meta: ["accept-event"])

    assert {:ok, %{waiting: false, messages: messages}} = MessageWaiting.decode(next_notify())
    assert messages == %{}

    summary = %{
      account: "sip:alice@127.0.0.1",
      voice: %{new: 2, old: 8, urgent_new: 1, urgent_old: 0}
    }

    :ok = MessageWaiting.put(PresServer, aor, summary)
    assert MessageWaiting.get(PresServer, aor) == summary

    assert {:ok, %{waiting: true, account: "sip:alice@127.0.0.1", messages: %{voice: voice}}} =
             MessageWaiting.decode(next_notify())

    assert voice == %{new: 2, old: 8, urgent_new: 1, urgent_old: 0}

    # Unchanged summaries are not notified
    :ok = MessageWaiting.put(PresServer, aor, summary)
    refute_receive {Client, {:notify, _}}, 200

    :ok = MessageWaiting.put(PresServer, aor, %{voice: %{new: 0, old: 10}})

    assert {:ok, %{waiting: false, messages: %{voice: %{new: 0, old: 10}}}} =
             MessageWaiting.decode(next_notify())

    assert {:ok, 200, _} = UAC.subscribe(subs, expires: 0)
  end

  test "conference state", %{port: port} do
    conf = {:sip, "room1", "127.0.0.1"}

    assert {:ok, 200, [subscription: subs]} =
             UAC.subscribe(Client, "sip:room1@127.0.0.1:#{port}", event: "conference")

    assert {:ok,
            %{version: 0, entity: "sip:room1@127.0.0.1", user_count: 0, active: false, users: []}} =
             Conference.decode(next_notify())

    :ok = Conference.put_description(PresServer, conf, %{subject: "Weekly", max_users: 10})

    assert {:ok, %{version: 1, description: %{subject: "Weekly", max_users: 10}}} =
             Conference.decode(next_notify())

    alice = %{
      entity: "sip:alice@example.com",
      display: "Alice & co",
      status: :connected,
      joining_method: "dialed-in",
      media: [%{id: "1", type: "audio", status: "sendrecv"}]
    }

    :ok = Conference.put_user(PresServer, conf, alice)

    :ok =
      Conference.put_user(PresServer, conf, %{entity: "sip:bob@example.com", status: :alerting})

    eventually(fn -> length(Conference.users(PresServer, conf)) == 2 end)
    doc = last_notify(fn doc -> length(doc.users) == 2 end)

    assert %{user_count: 2, active: true, locked: false} = doc

    assert [
             %{
               entity: "sip:alice@example.com",
               display: "Alice & co",
               endpoint: "sip:alice@example.com",
               status: :connected,
               joining_method: "dialed-in",
               media: [%{id: "1", type: "audio", status: "sendrecv"}]
             },
             %{entity: "sip:bob@example.com", status: :alerting}
           ] = doc.users

    # A user that leaves is notified once as disconnected, and forgotten
    :ok = Conference.remove_user(PresServer, conf, "sip:bob@example.com")
    doc = last_notify(fn doc -> Enum.any?(doc.users, &(&1.status == :disconnected)) end)
    assert doc.user_count == 1
    eventually(fn -> length(Conference.users(PresServer, conf)) == 1 end)

    assert {:ok, 200, [subscription: ^subs]} = UAC.subscribe(subs, expires: 0)

    assert {:ok, %{users: [%{entity: "sip:alice@example.com"}]}} =
             Conference.decode(next_notify())
  end

  # NOTIFYs until one matches (close changes may be notified together)
  defp last_notify(fun) do
    {:ok, doc} = Conference.decode(next_notify())
    if fun.(doc), do: doc, else: last_notify(fun)
  end
end
