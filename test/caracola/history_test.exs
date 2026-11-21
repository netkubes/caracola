defmodule Caracola.HistoryTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{History, UAC}
  alias Caracola.Test.{HistProxy1, HistProxy2, HistUAS, Repl1}

  import Caracola.Test.Helpers

  doctest Caracola.History

  setup do
    for service <- [Repl1, HistUAS, HistProxy1, HistProxy2], do: start_service(service)
    :ok
  end

  test "retargeted twice" do
    uri = "sip:alice@127.0.0.1:#{port(HistProxy1)}"
    assert {:ok, 200, [dialog: dialog]} = UAC.invite(Repl1, uri, [:auto_2xx_ack])
    assert_receive {:invite, req}

    assert req.ruri.user == "vm"
    assert {:ok, "486"} = Caracola.URI.get_param(req.ruri, "cause")

    assert [
             %{index: "1", type: nil, cause: nil, uri: %{user: "alice"}},
             %{index: "1.1", type: {:mp, "1"}, cause: 302, uri: %{user: "bob"}},
             %{index: "1.1.1", type: {:rc, "1.1"}, cause: 486, uri: %{user: "vm"}}
           ] = History.entries(req)

    assert [%{uri: %{user: "bob"}, reason: "user-busy", counter: 1}] = History.diversions(req)
    assert {:ok, 200, []} = UAC.bye(dialog)
  end
end
