defmodule Caracola.ReferTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Subscription, UAC}
  alias Caracola.Test.{Refer1, Refer2, Refer3}

  import Caracola.Test.Helpers

  # Ported and adapted from NkSIP's t19_refer. Refer1 asks Refer2 to call
  # Refer3, which rings and answers after 500ms.

  setup do
    for service <- [Refer1, Refer2, Refer3], do: start_service(service)
    target = "<sip:127.0.0.1:#{port(Refer3)}?x-op=ok&x-prov=true&x-sleep=500>"
    %{uri: "sip:127.0.0.1:#{port(Refer2)}", target: target}
  end

  defp refer_call_id({:subscription, _, call_id, _, _}), do: "caracola_refer_" <> call_id

  defp transfer_ends(subs) do
    assert_receive {Refer1, {:refer, ^subs, :active}}
    assert_receive {Refer1, {:refer, ^subs, {:notify, "SIP/2.0 180 Ringing"}}}
    assert_receive {Refer1, {:refer, ^subs, {:notify, "SIP/2.0 200 OK"}}}, 2000
    assert_receive {Refer1, {:refer, ^subs, :terminated}}
  end

  test "basic", %{uri: uri, target: target} do
    assert {:ok, 202, [subscription: subs]} = UAC.refer(Refer1, uri, refer_to: target)
    assert_receive {Refer1, {:refer, ^subs, :init}}
    assert_receive {Refer1, {:refer, ^subs, :active}}
    assert_receive {Refer1, {:refer, ^subs, {:notify, "SIP/2.0 180 Ringing"}}}

    {:ok, %Subscription{status: :active, event: {"refer", [{"id", _}]}, expires: 180}} =
      Subscription.get(subs)

    # The other side of the subscription
    {:subscription, _, call_id, _, _} = subs
    [dialog_b] = Dialog.list(Refer2, call_id)

    eventually(fn ->
      match?(
        {:ok, %Dialog{subscriptions: [%Subscription{status: :active}]}},
        Dialog.get(dialog_b)
      )
    end)

    # A refresh
    assert {:ok, 200, [subscription: ^subs]} = UAC.subscribe(subs, expires: 10)
    assert {:ok, %Subscription{expires: 10}} = Subscription.get(subs)

    # The INVITE from Refer2 to Refer3
    [dialog2] = Dialog.list(Refer2, refer_call_id(subs))
    {:ok, %Dialog{invite: %{status: :proceeding_uac}}} = Dialog.get(dialog2)

    assert_receive {Refer1, {:refer, ^subs, {:notify, "SIP/2.0 200 OK"}}}, 2000
    assert_receive {Refer1, {:refer, ^subs, :terminated}}
    eventually(fn -> Dialog.get(Subscription.dialog(subs)) == {:error, :unknown_dialog} end)

    # Ends the referred call
    eventually(fn ->
      match?({:ok, %Dialog{invite: %{status: :confirmed}}}, Dialog.get(dialog2))
    end)

    assert {:ok, 200, []} = UAC.bye(dialog2)
  end

  test "notify without id", %{uri: uri, target: target} do
    # As sent by pjsip (Asterisk): they belong to the first REFER
    assert {:ok, 202, [subscription: subs]} = UAC.refer(Refer1, uri, refer_to: target)
    assert_receive {Refer1, {:refer, ^subs, :active}}
    {:subscription, _, call_id, _, _} = subs
    [dialog_b] = Dialog.list(Refer2, call_id)

    assert {:ok, 200, []} =
             UAC.request(dialog_b, :notify,
               event: "refer",
               subscription_state: :active,
               content_type: "message/sipfrag;version=2.0",
               body: "SIP/2.0 183 Session Progress"
             )

    assert_receive {Refer1, {:refer, ^subs, {:notify, "SIP/2.0 183 Session Progress"}}}
    assert_receive {Refer1, {:refer, ^subs, {:notify, "SIP/2.0 200 OK"}}}, 2000
    assert_receive {Refer1, {:refer, ^subs, :terminated}}
  end

  test "in dialog", %{uri: uri, target: target} do
    assert {:ok, 200, [dialog: dialog]} =
             UAC.invite(Refer1, uri, [{:add, "x-op", "ok"}, :auto_2xx_ack])

    assert {:ok, 202, [subscription: subs]} = UAC.refer(dialog, refer_to: target)
    assert Subscription.dialog(subs) == dialog
    transfer_ends(subs)

    # The subscription ended, the dialog goes on
    eventually(fn -> match?({:ok, %Dialog{subscriptions: []}}, Dialog.get(dialog)) end)
    [dialog2] = Dialog.list(Refer2, refer_call_id(subs))

    eventually(fn ->
      match?({:ok, %Dialog{invite: %{status: :confirmed}}}, Dialog.get(dialog2))
    end)

    assert {:ok, 200, []} = UAC.bye(dialog2)
    assert {:ok, 200, []} = UAC.bye(dialog)
  end

  test "invalid and failed", %{uri: uri} do
    # Without Refer-To
    assert {:ok, 400, []} = UAC.refer(Refer1, uri)
    # The referred request fails
    assert {:ok, 202, [subscription: subs]} =
             UAC.refer(Refer1, uri, refer_to: "<sip:127.0.0.1:1;transport=tcp>")

    assert_receive {Refer1, {:refer, ^subs, {:notify, "SIP/2.0 503 Service Unavailable"}}}, 2000
    assert_receive {Refer1, {:refer, ^subs, :terminated}}
  end
end
