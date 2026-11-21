defmodule Caracola.B2BUATest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{B2BUA, Dialog, SDP, UAC}
  alias Caracola.Test.{B2B, Repl1, Repl2}

  import Caracola.Test.Helpers

  # Repl1 (A) calls Repl2 (B) through B2B

  setup do
    start_service(Repl1)
    start_service(Repl2)
    start_service(B2B, target: Repl2, sdp: "relayed")
    %{uri: fn user -> "sip:#{user}@127.0.0.1:#{port(B2B)}" end}
  end

  defp offer, do: SDP.new("repl1", [{"audio", 1000, [{:rtpmap, 0, "PCMU"}]}])

  defp call(uri, opts \\ []) do
    assert {:ok, 200, [dialog: a, body: body]} =
             UAC.invite(Repl1, uri, [:auto_2xx_ack, body: offer(), get_meta: [:body]] ++ opts)

    assert_receive {:b2bua, :answered, bridge}
    {a, bridge, body}
  end

  test "an answered call, hung up by A", %{uri: uri} do
    {a, bridge, body} = call(uri.("answer"), [{:add, "x-copied", "yes"}])

    # The SDP of B, changed by sip_b2bua_sdp
    assert {:ok, %SDP{session: "relayed b"}} = SDP.parse(body)
    assert bridge.status == :answered and bridge.meta == :test
    assert {:ok, ^bridge} = B2BUA.get(B2B, bridge.b_call_id)

    # The B leg has its own Call-ID, the From of A and the copied headers
    {:dialog, _, a_call_id, _} = a
    assert a_call_id == bridge.a_call_id and a_call_id != bridge.b_call_id
    assert [b] = Dialog.list(Repl2, bridge.b_call_id)
    {:ok, dialog} = Dialog.get(b)
    assert dialog.remote_uri.user == "repl1"
    assert dialog.invite.remote_sdp.session == "relayed a"

    assert {:ok, 200, []} = UAC.bye(a)
    assert_receive {Repl2, {:bye, _}}
    assert_receive {:b2bua, {:stop, {:bye, :a}}, _}
    eventually(fn -> B2BUA.get(B2B, a_call_id) == {:error, :not_found} end)
  end

  test "hung up by B", %{uri: uri} do
    {a, bridge, _body} = call(uri.("answer"))
    [b] = Dialog.list(Repl2, bridge.b_call_id)
    assert {:ok, 200, []} = UAC.bye(b)
    assert_receive {:b2bua, {:stop, {:bye, :b}}, _}
    eventually(fn -> Dialog.get(a) == {:error, :unknown_dialog} end)
  end

  test "rejected", %{uri: uri} do
    assert {:ok, 486, []} = UAC.invite(Repl1, uri.("busy"), body: offer())
    assert_receive {:b2bua, {:stop, {:rejected, 486}}, _}
  end

  test "ringing and cancelled", %{uri: uri} do
    assert {:async, handle} =
             UAC.invite(Repl1, uri.("answer"), [
               :async,
               {:add, "x-prov", "true"},
               {:add, "x-sleep", "2000"},
               body: offer(),
               callback: callback()
             ])

    assert_receive {:callback, {:resp, 180, _}}, 1000
    assert :ok = UAC.cancel(handle)
    assert_receive {:callback, {:resp, 487, _}}, 1000
    assert_receive {:b2bua, {:stop, :cancelled}, _}
  end

  test "in-dialog requests go to the other leg", %{uri: uri} do
    {a, bridge, _body} = call(uri.("answer"))

    # re-INVITE: B answers with a new SDP
    assert {:ok, 200, [dialog: ^a, body: body]} =
             UAC.invite(a, [:auto_2xx_ack, body: SDP.increment(offer()), get_meta: [:body]])

    assert {:ok, %SDP{session: "relayed b"}} = SDP.parse(body)

    # INFO with its body
    dtmf = "Signal=5\r\nDuration=160\r\n"

    assert {:ok, 200, []} =
             UAC.info(a, body: dtmf, content_type: "application/dtmf-relay")

    assert_receive {Repl2, {:info, info}}
    assert info.body == dtmf

    # A re-INVITE without SDP from B gets the last one sent to it
    [b] = Dialog.list(Repl2, bridge.b_call_id)
    assert {:ok, 200, [dialog: ^b, body: body]} = UAC.invite(b, get_meta: [:body])
    assert {:ok, %SDP{session: "relayed a"}} = SDP.parse(body)
    assert :ok = UAC.ack(b, body: SDP.increment(offer()))

    assert {:ok, 200, []} = UAC.bye(a)
  end

  test "delayed offer", %{uri: uri} do
    assert {:ok, 200, [dialog: a, body: body]} =
             UAC.invite(Repl1, uri.("answer"), get_meta: [:body])

    assert {:ok, %SDP{session: "relayed b"}} = SDP.parse(body)
    assert :ok = UAC.ack(a, body: offer())
    assert_receive {:b2bua, :answered, bridge}

    [b] = Dialog.list(Repl2, bridge.b_call_id)

    eventually(fn ->
      match?({:ok, %Dialog{invite: %{remote_sdp: %SDP{session: "relayed a"}}}}, Dialog.get(b))
    end)

    assert {:ok, 200, []} = UAC.bye(a)
  end

  test "hangup", %{uri: uri} do
    {a, bridge, _body} = call(uri.("answer"))
    assert :ok = B2BUA.hangup(B2B, bridge.a_call_id)
    assert_receive {:b2bua, {:stop, :hangup}, _}
    assert_receive {Repl2, {:bye, _}}
    eventually(fn -> Dialog.get(a) == {:error, :unknown_dialog} end)
    assert {:error, :not_found} = B2BUA.hangup(B2B, bridge.a_call_id)
  end
end
