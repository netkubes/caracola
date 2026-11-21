defmodule Caracola.ReplacesTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Replaces, UAC}
  alias Caracola.Test.{Repl1, Repl2, Repl3}

  import Caracola.Test.Helpers

  # Repl1 (A) talks to Repl2 (B) and Repl3 (C)

  setup do
    for service <- [Repl1, Repl2, Repl3], do: start_service(service)
    %{b: "sip:ok@127.0.0.1:#{port(Repl2)}", c: "sip:ok@127.0.0.1:#{port(Repl3)}"}
  end

  defp call(from, uri) do
    assert {:ok, 200, [dialog: dialog]} = UAC.invite(from, uri, [:auto_2xx_ack])
    dialog
  end

  # The dialog of the other side
  defp remote({:dialog, _, call_id, _}, service) do
    [dialog] = Dialog.list(service, call_id)
    dialog
  end

  test "supported", %{b: b} do
    assert {:ok, 200, [{:dialog, dialog}, {"supported", supported}]} =
             UAC.invite(Repl1, b, [:auto_2xx_ack, get_meta: ["supported"]])

    assert Enum.any?(supported, &(&1 =~ "replaces"))
    assert {:ok, 200, []} = UAC.bye(dialog)
  end

  test "attended transfer", %{b: b, c: c} do
    ab = call(Repl1, b)
    ac = call(Repl1, c)
    ca = remote(ac, Repl3)

    # A transfers B to C: B calls C replacing the dialog of A and C
    assert {:ok, refer_to} = Replaces.refer_to(c, ac)
    assert refer_to =~ "?Replaces="
    assert {:ok, 202, [subscription: subs]} = UAC.refer(ab, refer_to: refer_to)
    assert_receive {Repl1, {:refer, ^subs, {:notify, "SIP/2.0 200 OK"}}}, 2000

    # C hangs up A
    eventually(fn -> Dialog.get(ac) == {:error, :unknown_dialog} end)
    eventually(fn -> Dialog.get(ca) == {:error, :unknown_dialog} end)

    # B and C are talking
    {:subscription, _, call_id, _, _} = subs
    [bc] = Dialog.list(Repl2, "caracola_refer_" <> call_id)
    assert {:ok, %Dialog{invite: %{status: :confirmed}}} = Dialog.get(bc)
    assert {:ok, 200, []} = UAC.bye(ab)
    assert {:ok, 200, []} = UAC.bye(bc)
  end

  test "replaced dialog not found or not replaceable", %{b: b, c: c} do
    ac = call(Repl1, c)
    {:ok, value} = Replaces.header(ac)
    replaces = fn value -> [:auto_2xx_ack, {:add, "replaces", value}] end

    # Unknown dialog
    assert {:ok, 481, []} = UAC.invite(Repl2, c, replaces.("unknown;to-tag=a;from-tag=b"))

    # early-only, for a confirmed dialog
    assert {:ok, 486, []} = UAC.invite(Repl2, c, replaces.(value <> ";early-only"))

    # Invalid
    assert {:ok, 400, []} = UAC.invite(Repl2, c, replaces.("callid;to-tag=a"))

    # An early dialog C did not start
    early =
      UAC.invite(
        Repl1,
        b,
        [:async, {:add, "x-prov", "true"}, {:add, "x-sleep", "2000"}] ++
          [callback: callback()]
      )

    assert {:async, _} = early
    assert_receive {:callback, {:resp, 180, resp}}
    {:ok, early_value} = Replaces.header(Dialog.handle(%{resp | service: Repl1}))
    b_early = "sip:ok@127.0.0.1:#{port(Repl2)}"
    assert {:ok, 481, []} = UAC.invite(Repl3, b_early, replaces.(early_value))
    assert {:ok, 200, []} = UAC.bye(ac)
  end

  test "an early dialog started by this UA is cancelled", %{b: b, c: c} do
    # C calls B, which rings
    assert {:async, _} =
             UAC.invite(
               Repl3,
               b,
               [:async, {:add, "x-prov", "true"}, {:add, "x-sleep", "3000"}] ++
                 [callback: callback()]
             )

    assert_receive {:callback, {:resp, 180, %{call_id: call_id}}}
    [bc] = Dialog.list(Repl2, call_id)

    # A replaces it (as seen by C, from the dialog of B)
    {:ok, value} = Replaces.header(bc)

    assert {:ok, 200, [dialog: ac]} =
             UAC.invite(Repl1, c, [:auto_2xx_ack, {:add, "replaces", value}])

    assert_receive {:callback, {:resp, 487, _}}, 2000
    assert {:ok, 200, []} = UAC.bye(ac)
  end
end
