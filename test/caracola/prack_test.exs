defmodule Caracola.PrackTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Message, SDP, UAC}
  alias Caracola.Test.{Rel1, Rel2}

  import Caracola.Test.Helpers

  # Ported and adapted from NkSIP's t17_prack and the basic and pending
  # tests of t12_update (which need reliable provisional responses)

  setup ctx do
    start_service(Rel1)
    port = start_service(Rel2, Map.get(ctx, :rel2, []))
    %{uri: "sip:ok@127.0.0.1:#{port}"}
  end

  defp sdp, do: SDP.new("rel1", [{"test", 1234, [{:rtpmap, 0, "codec1"}]}])

  defp rack(rseq, cseq), do: "#{rseq} #{cseq} INVITE"

  defp rseq(resp) do
    [rseq] = Message.header(resp, "rseq")
    String.to_integer(rseq)
  end

  test "reliable provisional responses", %{uri: uri} do
    # Not required: not reliable
    assert {:ok, 486, [{"supported", supported}, {"require", []}]} =
             UAC.invite(Rel1, uri, [
               {:add, "x-op", "prov-busy"},
               callback: callback(),
               get_meta: ["supported", "require"]
             ])

    assert Enum.any?(supported, &(&1 =~ "100rel"))
    assert_receive {:callback, {:resp, 180, %Message{require: []}}}
    assert_receive {:callback, {:resp, 183, %Message{require: []}}}
    refute_received {Rel2, {:prack, _}}

    # Required: reliable, with consecutive RSeq, and acknowledged
    assert {:ok, 486, [cseq_num: cseq, rseq_num: nil]} =
             UAC.invite(Rel1, uri, [
               {:add, "x-op", "rel-prov-busy"},
               require: "100rel",
               callback: callback(),
               get_meta: [:cseq_num, :rseq_num]
             ])

    assert_receive {:callback, {:resp, 180, %Message{require: ["100rel"]} = resp1}}
    assert_receive {:callback, {:resp, 183, %Message{require: ["100rel"]} = resp2}}
    rseq = rseq(resp1)
    assert rseq(resp2) == rseq + 1
    assert_receive {Rel2, {:prack, rack1}}
    assert_receive {Rel2, {:prack, rack2}}
    assert rack1 == rack(rseq, cseq)
    assert rack2 == rack(rseq + 1, cseq)
  end

  test "through a stateful proxy", %{uri: uri} do
    # The proxy forwards reliable responses as they are, and their PRACKs
    start_service(Caracola.Test.Proxy, proxy: [opts: [:record_route]])

    assert {:ok, 486, [cseq_num: cseq]} =
             UAC.invite(Rel1, uri, [
               {:add, "x-op", "rel-prov-busy"},
               require: "100rel",
               route: route(Caracola.Test.Proxy),
               callback: callback(),
               get_meta: [:cseq_num]
             ])

    assert_receive {:callback, {:resp, 180, resp1}}
    assert_receive {:callback, {:resp, 183, resp2}}
    assert rseq(resp2) == rseq(resp1) + 1
    assert_receive {Rel2, {:prack, rack1}}
    assert_receive {Rel2, {:prack, rack2}}
    assert rack1 == rack(rseq(resp1), cseq)
    assert rack2 == rack(rseq(resp2), cseq)
  end

  test "pending PRACK", %{uri: uri} do
    assert {:ok, 486, []} = UAC.invite(Rel1, uri, [{:add, "x-op", "pending"}])
    assert_receive {Rel2, :pending_prack_ok}
  end

  test "offer/answer in reliable responses and PRACK", %{uri: uri} do
    sdp = sdp()

    # Offer in INVITE, answer in 180 (and new versions in 183 and 200)
    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Rel1, uri, [{:add, "x-op", "rel-prov-answer"}, body: sdp])

    assert UAC.ack(dia) == :ok
    assert_receive {Rel2, {:prack, _}}
    assert_receive {Rel2, {:prack, _}}
    assert_receive {Rel2, {:session, {:start, remote, ^sdp}}}
    assert_receive {Rel2, {:session, {:update, _, ^sdp}}}
    assert_receive {Rel2, {:session, {:update, remote2, ^sdp}}}
    assert remote2.vsn == remote.vsn + 2
    assert {:ok, 200, []} = UAC.bye(dia)
    assert_receive {Rel2, {:session, :stop}}

    # Offer in INVITE, answer in 180, new offer in PRACK
    callback = fn nil, {:resp, 180, _} -> SDP.increment(sdp) end

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Rel1, uri, [
               {:add, "x-op", "rel-prov-answer2"},
               body: sdp,
               prack_callback: callback
             ])

    assert UAC.ack(dia) == :ok
    assert_receive {Rel2, {:session, {:start, _, ^sdp}}}
    assert_receive {Rel2, {:session, {:update, _, local2}}}
    assert local2.vsn == sdp.vsn + 1
    {:ok, a} = Dialog.get(dia)
    assert a.invite.local_sdp == local2
    assert {:ok, 200, []} = UAC.bye(dia)

    # Offer in 180, answer in PRACK
    pid = self()

    callback = fn %SDP{} = offer, {:resp, 180, _} ->
      answer = %{offer | address: {"IN", "IP4", "rel1"}}
      send(pid, {:answer, answer})
      answer
    end

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Rel1, uri, [{:add, "x-op", "rel-prov-answer3"}, prack_callback: callback])

    assert UAC.ack(dia) == :ok
    assert_receive {:answer, answer}
    assert_receive {Rel2, {:session, {:start, offer, ^answer}}}
    {:ok, a} = Dialog.get(dia)
    assert {a.invite.local_sdp, a.invite.remote_sdp} == {answer, offer}
    assert {:ok, 200, []} = UAC.bye(dia)
  end

  test "update in an early dialog", %{uri: uri} do
    sdp = sdp()
    pid = self()

    # When the reliable 180 arrives, the caller sends an UPDATE with a new
    # offer and the callee another one
    callback = fn
      {:resp, 180, resp} ->
        spawn(fn ->
          dia = Dialog.handle(resp)
          sdp2 = SDP.increment(sdp)
          {:ok, 200, []} = UAC.update(dia, [{:add, "x-op", "increment"}, body: sdp2])
          send(pid, {:update, 1})
        end)

      _ ->
        :ok
    end

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Rel1, uri, [
               {:add, "x-op", "rel-prov-answer-wait"},
               body: sdp,
               callback: callback
             ])

    assert_receive {:update, 1}
    assert UAC.ack(dia) == :ok
    assert_receive {Rel2, {:session, {:start, _, ^sdp}}}
    assert_receive {Rel2, {:session, {:update, local, remote}}}
    assert remote.vsn == sdp.vsn + 1
    {:ok, a} = Dialog.get(dia)
    assert {a.invite.local_sdp, a.invite.remote_sdp} == {remote, local}

    # No UPDATE with an offer while another one is pending: the INVITE in
    # progress has an offer without answer
    assert {:async, _} =
             UAC.invite(dia, [
               {:add, "x-op", "ok"},
               {:add, "x-sleep", "300"},
               :async,
               body: SDP.increment(remote)
             ])

    Process.sleep(50)
    assert UAC.update(dia, body: SDP.increment(remote)) == {:error, :request_pending}
    assert {:ok, 200, []} = UAC.bye(dia)
  end

  @tag rel2: [sip: [timer_t1: 10]]
  test "retransmission and timeout without PRACK", %{uri: uri} do
    start_service(Caracola.Test.Client)

    # The client does not support 100rel, but requires it
    assert {:ok, 500, [reason_phrase: "Reliable Provisional Response Timeout"]} =
             UAC.invite(Caracola.Test.Client, uri, [
               {:add, "x-op", "rel-ringing"},
               require: "100rel",
               callback: callback(),
               get_meta: [:reason_phrase]
             ])

    assert_receive {:callback, {:resp, 180, %Message{require: ["100rel"]} = resp}}
    rseq = rseq(resp)
    # Retransmissions
    assert_receive {:callback, {:resp, 180, %Message{} = resp}}
    assert rseq(resp) == rseq
  end
end
