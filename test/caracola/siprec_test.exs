defmodule Caracola.SiprecTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{B2BUA, Message, SDP, Siprec, UAC}
  alias Caracola.Test.{B2B, Repl1, Repl2, SRS}

  import Caracola.Test.Helpers

  setup do
    for service <- [Repl1, Repl2, SRS], do: start_service(service)
    %{srs: "sip:srs@127.0.0.1:#{port(SRS)}"}
  end

  defp media_sdp do
    SDP.new("src", [
      {"audio", 2000, [{:rtpmap, 0, "PCMU"}]},
      {"audio", 2002, [{:rtpmap, 0, "PCMU"}]}
    ])
  end

  test "a recording session", %{srs: srs} do
    recording = %{
      call_id: "recorded-call",
      participants: [
        %{aor: "sip:alice@example.com", name: "Alice & Co", send: [1]},
        %{aor: "sip:bob@example.com", send: [2]}
      ],
      sdp: media_sdp()
    }

    assert {:ok, 200, [dialog: dialog]} = Siprec.record(Repl1, srs, recording)
    assert_receive {:recording, req, %{sdp: sdp, metadata: meta}}

    assert Message.header(req, "require") == ["siprec"]

    assert [%{attributes: attrs1}, %{attributes: attrs2}] = sdp.medias
    assert {"label", ["1"]} in attrs1 and {"sendonly", []} in attrs1
    assert {"label", ["2"]} in attrs2

    assert meta.call_id == "recorded-call"
    assert is_binary(meta.session_id) and is_binary(meta.start_time)
    assert [%{label: "1"}, %{label: "2"}] = meta.streams

    assert [
             %{aor: "sip:alice@example.com", name: "Alice & Co", send: ["1"], recv: ["2"]},
             %{aor: "sip:bob@example.com", name: nil, send: ["2"], recv: ["1"]}
           ] = meta.participants

    assert {:ok, 200, []} = UAC.bye(dialog)
  end

  test "not a recording session", %{srs: srs} do
    assert {:ok, 403, []} = UAC.invite(Repl1, srs)
  end

  test "recording a bridged call", %{srs: srs} do
    start_service(B2B, target: Repl2)

    assert {:ok, 200, [dialog: a]} =
             UAC.invite(Repl1, "sip:answer@127.0.0.1:#{port(B2B)}", [
               :auto_2xx_ack,
               body: media_sdp()
             ])

    assert_receive {:b2bua, :answered, bridge}
    assert {:ok, recording} = Siprec.bridge(bridge, media_sdp())
    assert {:ok, 200, [dialog: rec]} = Siprec.record(B2B, srs, recording)
    assert_receive {:recording, _req, %{metadata: meta}}

    assert meta.call_id == bridge.a_call_id

    assert [
             %{aor: "sip:repl1@caracola", send: ["1"]},
             %{aor: "sip:answer@127.0.0.1", send: ["2"]}
           ] =
             meta.participants

    assert {:ok, 200, []} = UAC.bye(rec)
    assert {:ok, 200, []} = UAC.bye(a)
    assert Siprec.bridge(%B2BUA{}, media_sdp()) == {:error, :not_answered}
  end
end
