defmodule Caracola.WatcherInfoTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{MessageWaiting, Notifier, UAC, WatcherInfo}
  alias Caracola.Test.{Repl1, Repl2, WinfoServer}

  import Caracola.Test.Helpers

  # Repl1 is alice, the presentity; Repl2 (repl2@caracola) a watcher

  setup do
    for service <- [Repl1, Repl2, WinfoServer], do: start_service(service)
    %{alice: "sip:alice@127.0.0.1:#{port(WinfoServer)}", aor: {:sip, "alice", "127.0.0.1"}}
  end

  defp winfo do
    assert_receive {Repl1, {:notify, body}}, 2000

    assert {:ok, %{state: :full, lists: [%{package: "message-summary"} = list]}} =
             WatcherInfo.decode(body)

    assert list.resource == "sip:alice@127.0.0.1"
    list.watchers
  end

  test "pending watchers, approved and rejected", %{alice: alice, aor: aor} do
    :ok = MessageWaiting.put(WinfoServer, aor, %{voice: %{new: 1, old: 0}})

    # Only alice can see her watchers
    assert {:ok, 403, []} = UAC.subscribe(Repl2, alice, event: "message-summary.winfo")

    assert {:ok, 200, [subscription: winfo_subs]} =
             UAC.subscribe(Repl1, alice,
               event: "message-summary.winfo",
               from: "<sip:alice@127.0.0.1>"
             )

    assert winfo() == []

    # A pending watcher gets no state
    assert {:ok, 200, [subscription: _]} =
             UAC.subscribe(Repl2, alice, event: "message-summary")

    assert_receive {Repl2, {:notify, ""}}, 2000

    assert [%{status: :pending, event: "subscribe", uri: "sip:repl2@caracola", id: id}] = winfo()

    assert [%{status: :pending, handle: handle}] =
             Notifier.watcher_info(WinfoServer, "message-summary", aor)

    # Approved: it gets the state
    assert :ok = Notifier.approve(handle)
    assert_receive {Repl2, {:notify, body}}, 2000
    assert {:ok, %{waiting: true}} = MessageWaiting.decode(body)
    assert [%{status: :active, id: ^id}] = winfo()

    # Rejected: shown as terminated, and then removed
    assert :ok = Notifier.terminate(handle)
    assert [%{status: :terminated, event: "rejected", id: ^id}] = winfo()
    assert winfo() == []
    assert Notifier.watcher_info(WinfoServer, "message-summary", aor) == []
    assert Notifier.approve(handle) == {:error, :not_found}

    assert {:ok, 200, _} = UAC.subscribe(winfo_subs, expires: 0)
  end
end
