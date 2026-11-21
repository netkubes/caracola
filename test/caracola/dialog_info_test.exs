defmodule Caracola.DialogInfoTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{DialogInfo, Notifier, UAC}
  alias Caracola.Test.{Client, PresServer, Server2}

  import Caracola.Test.Helpers

  doctest DialogInfo

  setup do
    port = start_service(PresServer)
    start_service(Client)
    start_service(Server2)
    %{port: port}
  end

  defp next_notify do
    assert_receive {Client, {:notify, body}}, 2000
    assert {:ok, %{state: :full} = doc} = DialogInfo.decode(body)
    doc
  end

  # States notified until the dialog ends (repeated states may be skipped)
  defp states(acc \\ []) do
    case next_notify() do
      %{dialogs: [%{state: :terminated}]} = doc -> Enum.reverse([doc | acc])
      doc -> states([doc | acc])
    end
  end

  test "dialogs of the service", %{port: port} do
    aor = {:sip, "bob", "127.0.0.1"}
    bob = "sip:bob@127.0.0.1:#{port}"

    assert {:ok, 200, [subscription: subs]} = UAC.subscribe(Client, bob, event: "dialog")
    assert %{version: 0, entity: "sip:bob@127.0.0.1", dialogs: []} = next_notify()

    # An incoming call: early, confirmed and terminated (the NOTIFYs have
    # the state when they are sent, so close changes may be notified once)
    assert {:ok, 200, [dialog: dialog]} =
             UAC.invite(Server2, bob, [
               :auto_2xx_ack,
               {:add, "x-op", "ok"},
               {:add, "x-prov", "true"},
               {:add, "x-sleep", "300"},
               from: "\"Ann\" <sip:ann@example.com>"
             ])

    eventually(fn -> match?([%{state: :confirmed}], DialogInfo.dialogs(PresServer, aor)) end)
    assert {:ok, 200, []} = UAC.bye(dialog)
    docs = states()

    assert Enum.map(docs, & &1.version) == Enum.to_list(1..length(docs))
    assert [%{dialogs: [%{state: :early}]} | _] = docs
    assert Enum.any?(docs, &match?(%{dialogs: [%{state: :confirmed}]}, &1))
    {:dialog, _, call_id, _} = dialog

    assert %{
             call_id: ^call_id,
             direction: :recipient,
             local: %{identity: "sip:bob@127.0.0.1"},
             remote: %{identity: "sip:ann@example.com", display: "Ann"}
           } = hd(List.last(docs).dialogs)

    # Terminated dialogs are forgotten
    eventually(fn -> DialogInfo.dialogs(PresServer, aor) == [] end)
    assert {:ok, 200, [subscription: ^subs]} = UAC.subscribe(subs, expires: 0)
    # Repeated notifications of the terminated dialog may still arrive
    eventually(fn -> match?(%{dialogs: []}, next_notify()) end)

    # An outgoing call
    assert {:ok, 200, [subscription: _]} =
             UAC.subscribe(Client, "sip:dave@127.0.0.1:#{port}", event: "dialog")

    assert %{version: 0, dialogs: []} = next_notify()

    assert {:ok, 200, [dialog: dialog]} =
             UAC.invite(PresServer, "sip:ok@127.0.0.1:#{port(Server2)}", [
               :auto_2xx_ack,
               from: "<sip:dave@127.0.0.1>"
             ])

    assert %{dialogs: [%{direction: :initiator}]} = hd(states_until_confirmed())
    assert {:ok, 200, []} = UAC.bye(dialog)

    assert [%{dialogs: [%{state: :terminated, direction: :initiator}]} | _] =
             Enum.reverse(states())
  end

  defp states_until_confirmed do
    case next_notify() do
      %{dialogs: [%{state: :confirmed}]} = doc -> [doc]
      doc -> [doc | states_until_confirmed()]
    end
  end

  test "dialogs set by the service", %{port: port} do
    aor = {:sip, "carol", "example.com"}
    route = "<sip:127.0.0.1:#{port};lr>"

    assert {:ok, 200, [subscription: _]} =
             UAC.subscribe(Client, "sip:carol@example.com", event: "dialog", route: route)

    assert %{entity: "sip:carol@example.com", dialogs: []} = next_notify()
    assert [_] = Notifier.watchers(PresServer, "dialog", aor)

    dialog = %{id: "d1", state: :confirmed, direction: :initiator, call_id: "c1"}
    assert DialogInfo.put(PresServer, aor, dialog) == :ok
    assert %{version: 1, dialogs: [%{id: "d1", state: :confirmed}]} = next_notify()

    # Without changes, nothing is sent
    assert DialogInfo.put(PresServer, aor, dialog) == :ok
    refute_receive {Client, {:notify, _}}, 200

    DialogInfo.put(PresServer, aor, %{dialog | state: :terminated} |> Map.put(:code, 487))

    assert %{version: 2, dialogs: [%{id: "d1", state: :terminated, code: 487}]} =
             next_notify()

    eventually(fn -> DialogInfo.dialogs(PresServer, aor) == [] end)
  end

  test "dialog-info documents" do
    # As sent by Asterisk
    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dialog-info xmlns="urn:ietf:params:xml:ns:dialog-info" version="4" state="full" entity="sip:1001@192.0.2.1">
     <dialog id="1001" direction="recipient">
      <remote>
       <identity display="Alice">sip:1002@192.0.2.1</identity>
       <target uri="sip:1002@192.0.2.1"/>
      </remote>
      <state>early</state>
      <local>
       <target uri="sip:1001@192.0.2.1"/>
      </local>
     </dialog>
    </dialog-info>
    """

    assert {:ok,
            %{
              version: 4,
              state: :full,
              entity: "sip:1001@192.0.2.1",
              dialogs: [
                %{
                  id: "1001",
                  direction: :recipient,
                  state: :early,
                  call_id: nil,
                  remote: %{identity: "sip:1002@192.0.2.1", display: "Alice"},
                  local: %{identity: nil, target: "sip:1001@192.0.2.1"}
                } = dialog
              ]
            }} = DialogInfo.decode(body)

    # Encoded and decoded back
    assert {:ok, %{dialogs: [^dialog]}} =
             DialogInfo.decode(DialogInfo.encode("sip:x", 0, [dialog]))

    assert {:ok, %{dialogs: [%{state: :terminated, event: "rejected", code: 486}]}} =
             DialogInfo.encode("sip:x", 1, [
               %{id: "a", state: :terminated, event: "rejected", code: 486}
             ])
             |> DialogInfo.decode()

    assert DialogInfo.decode("<presence/>") == :error
  end
end
