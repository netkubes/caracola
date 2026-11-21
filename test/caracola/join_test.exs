defmodule Caracola.JoinTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Join, Message, Replaces, UAC}
  alias Caracola.Test.{Repl1, Repl2, Repl3}

  import Caracola.Test.Helpers

  # Repl1 (A) talks to Repl2 (B) and Repl3 (C)

  setup do
    for service <- [Repl1, Repl2, Repl3], do: start_service(service)
    %{b: "sip:ok@127.0.0.1:#{port(Repl2)}", c: "sip:ok@127.0.0.1:#{port(Repl3)}"}
  end

  defp call(from, uri, opts \\ []) do
    assert {:ok, 200, [dialog: dialog]} = UAC.invite(from, uri, [:auto_2xx_ack | opts])
    dialog
  end

  defp confirmed?(dialog),
    do: match?({:ok, %Dialog{invite: %{status: :confirmed}}}, Dialog.get(dialog))

  test "supported", %{b: b} do
    assert {:ok, 200, [{:dialog, dialog}, {"supported", supported}]} =
             UAC.invite(Repl1, b, [:auto_2xx_ack, get_meta: ["supported"]])

    assert Enum.any?(supported, &(&1 =~ "join"))
    assert {:ok, 200, []} = UAC.bye(dialog)
  end

  test "a new dialog joins an existing one", %{c: c} do
    ac = call(Repl1, c)
    {:ok, value} = Join.header(ac)

    # B joins the call of A at C: both dialogs go on
    bc = call(Repl2, c, [{:add, "join", value}])
    Process.sleep(100)
    assert confirmed?(ac)
    assert confirmed?(bc)

    {:dialog, _, ac_call_id, _} = ac
    {:dialog, _, bc_call_id, _} = bc
    assert length(Dialog.list(Repl3, ac_call_id)) == 1
    assert length(Dialog.list(Repl3, bc_call_id)) == 1

    assert {:ok, 200, []} = UAC.bye(ac)
    assert {:ok, 200, []} = UAC.bye(bc)
  end

  test "joining through a REFER", %{b: b, c: c} do
    ab = call(Repl1, b)
    ac = call(Repl1, c)

    # A asks B to join its call with C
    assert {:ok, refer_to} = Join.refer_to(c, ac)
    assert refer_to =~ "?Join="
    assert {:ok, 202, [subscription: subs]} = UAC.refer(ab, refer_to: refer_to)
    assert_receive {Repl1, {:refer, ^subs, {:notify, "SIP/2.0 200 OK"}}}, 2000

    {:subscription, _, call_id, _, _} = subs
    [bc] = Dialog.list(Repl2, "caracola_refer_" <> call_id)
    assert confirmed?(bc)
    assert confirmed?(ac)

    for dialog <- [ab, ac, bc], do: assert({:ok, 200, []} = UAC.bye(dialog))
  end

  test "joined dialog not found or not joinable", %{c: c} do
    ac = call(Repl1, c)
    {:ok, value} = Join.header(ac)
    join = fn value -> [:auto_2xx_ack, {:add, "join", value}] end

    assert {:ok, 481, []} = UAC.invite(Repl2, c, join.("unknown;to-tag=a;from-tag=b"))
    assert {:ok, 400, []} = UAC.invite(Repl2, c, join.("callid;to-tag=a"))

    {:ok, replaces} = Replaces.header(ac)

    assert {:ok, 400, []} =
             UAC.invite(Repl2, c, join.(value) ++ [{:add, "replaces", replaces}])

    assert confirmed?(ac)
    assert {:ok, 200, []} = UAC.bye(ac)
  end

  test "joined dialog of a request" do
    {:ok, req} =
      Message.update_header(%Message{service: Repl1}, :add, "join", "abc;to-tag=1;from-tag=2")

    assert {:dialog, Repl1, "abc", _id} = Join.joined(req)
    assert Join.joined(%Message{service: Repl1}) == nil
  end
end
