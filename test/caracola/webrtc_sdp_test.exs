defmodule Caracola.SDP.WebRTCTest do
  use ExUnit.Case, async: true

  alias Caracola.SDP
  alias Caracola.SDP.WebRTC

  doctest WebRTC

  # An offer as sent by a browser
  @offer """
  v=0\r
  o=- 4611731400430051336 2 IN IP4 127.0.0.1\r
  s=-\r
  t=0 0\r
  a=group:BUNDLE 0 1\r
  a=extmap-allow-mixed\r
  a=msid-semantic: WMS stream\r
  m=audio 9 UDP/TLS/RTP/SAVPF 111 9 0 126\r
  c=IN IP4 0.0.0.0\r
  a=rtcp:9 IN IP4 0.0.0.0\r
  a=ice-ufrag:AbCd\r
  a=ice-pwd:EfGhIjKlMnOpQrStUvWxYz01\r
  a=ice-options:trickle\r
  a=fingerprint:sha-256 4A:AD:B9:B1:3F:82:18:3B:54:02:12:DF:3E:5D:49:6B:19:E5:7C:AB:74:E4:3D:6B:3B:4F:21:5A:3E:A4:76:5C\r
  a=setup:actpass\r
  a=mid:0\r
  a=sendrecv\r
  a=rtcp-mux\r
  a=rtpmap:111 opus/48000/2\r
  a=rtcp-fb:111 transport-cc\r
  a=fmtp:111 minptime=10;useinbandfec=1\r
  a=rtpmap:9 G722/8000\r
  a=rtpmap:0 PCMU/8000\r
  a=rtpmap:126 telephone-event/8000\r
  a=candidate:1 1 udp 2122260223 192.168.1.10 54400 typ host generation 0\r
  m=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103\r
  c=IN IP4 0.0.0.0\r
  a=ice-ufrag:AbCd\r
  a=ice-pwd:EfGhIjKlMnOpQrStUvWxYz01\r
  a=fingerprint:sha-256 4A:AD:B9:B1:3F:82:18:3B:54:02:12:DF:3E:5D:49:6B:19:E5:7C:AB:74:E4:3D:6B:3B:4F:21:5A:3E:A4:76:5C\r
  a=setup:actpass\r
  a=mid:1\r
  a=sendrecv\r
  a=rtcp-mux\r
  a=rtpmap:96 VP8/90000\r
  a=rtcp-fb:96 nack\r
  a=rtcp-fb:96 nack pli\r
  a=rtpmap:97 rtx/90000\r
  a=fmtp:97 apt=96\r
  a=rtpmap:102 H264/90000\r
  a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f\r
  a=rtpmap:103 rtx/90000\r
  a=fmtp:103 apt=102\r
  """

  setup do
    {:ok, sdp} = SDP.parse(@offer)
    %{sdp: sdp}
  end

  test "medias, bundle and DTLS", %{sdp: sdp} do
    [audio, video] = sdp.medias
    assert {WebRTC.mid(audio), WebRTC.mid(video)} == {"0", "1"}
    assert WebRTC.bundle(sdp) == ["0", "1"]
    assert WebRTC.rtcp_mux?(audio) and WebRTC.secure?(video)
    refute WebRTC.secure?(%SDP.Media{proto: "RTP/AVP"})

    assert %{ufrag: "AbCd", pwd: "EfGhIjKlMnOpQrStUvWxYz01", options: ["trickle"], lite: false} =
             WebRTC.ice(sdp)

    assert {"sha-256", "4A:AD:" <> _} = WebRTC.fingerprint(sdp, 1)
    assert WebRTC.setup(sdp, 1) == :actpass
    assert WebRTC.answer_setup(WebRTC.setup(sdp)) == :active
    assert WebRTC.fingerprint(sdp, 5) == nil
  end

  test "candidates", %{sdp: sdp} do
    assert [%{mid: "0", index: 0, candidate: "candidate:1 1 udp " <> _ = line}] =
             WebRTC.candidates(sdp)

    assert {:ok, %{type: "host", port: 54_400, transport: "udp", raddr: nil}} =
             WebRTC.parse_candidate(line)

    assert WebRTC.parse_candidate("candidate:1 1 udp") == :error

    # By mid, or by index when the media has no mid
    new = [
      %{
        candidate: "candidate:2 1 udp 1686052607 203.0.113.5 54401 typ srflx",
        mid: "1",
        index: 9
      },
      %{candidate: "candidate:3 1 tcp 1518280447 192.168.1.10 9 typ host", mid: "9", index: 0}
    ]

    sdp2 = WebRTC.add_candidates(sdp, new)
    assert [%{mid: "0"}, %{mid: "1", index: 1}] = WebRTC.candidates(sdp2)

    # The SDP is encoded and parsed back
    assert {:ok, sdp3} = SDP.parse(SDP.encode(sdp2))
    assert WebRTC.candidates(sdp3) == WebRTC.candidates(sdp2)

    no_mids = %{sdp | medias: Enum.map(sdp.medias, &%{&1 | attributes: []})}
    assert [%{index: 0, mid: nil}] = WebRTC.candidates(WebRTC.add_candidates(no_mids, new))
  end

  test "trickle ICE sdpfrag (RFC 8840)", %{sdp: sdp} do
    candidates = [
      %{candidate: "candidate:2 1 udp 1686052607 203.0.113.5 54401 typ srflx", mid: "1", index: 1}
    ]

    body = WebRTC.sdpfrag(sdp, candidates, end_of_candidates: true)
    assert body =~ "a=ice-ufrag:AbCd\r\na=ice-pwd:EfGhIjKlMnOpQrStUvWxYz01\r\n"
    assert body =~ "m=audio 9 UDP/TLS/RTP/SAVPF 111 9 0 126\r\na=mid:0\r\na=candidate:1 1 udp"
    assert body =~ "m=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103\r\na=mid:1\r\na=candidate:2"
    assert String.ends_with?(body, "a=end-of-candidates\r\n")

    assert {:ok,
            %{
              ufrag: "AbCd",
              pwd: "EfGhIjKlMnOpQrStUvWxYz01",
              end_of_candidates: true,
              candidates: [%{mid: "0", index: 0}, %{mid: "1", index: 1} = c]
            }} = WebRTC.parse_sdpfrag(body)

    assert c.candidate == hd(candidates).candidate
    assert WebRTC.sdpfrag_content_type() == "application/trickle-ice-sdpfrag"

    # mid after the candidate, and LF line endings
    frag =
      "a=ice-ufrag:x\nm=audio 9 RTP/AVP 0\na=candidate:1 1 udp 1 1.2.3.4 5 typ host\na=mid:a\n"

    assert {:ok, %{candidates: [%{mid: "a", index: 0}], end_of_candidates: false}} =
             WebRTC.parse_sdpfrag(frag)

    assert WebRTC.parse_sdpfrag("not sdp") == :error
  end

  test "codecs", %{sdp: sdp} do
    [audio, video] = sdp.medias

    assert [
             %{
               pt: "111",
               name: "opus",
               rate: 48_000,
               channels: 2,
               fmtp: ["minptime=10;useinbandfec=1"],
               rtcp_fb: ["transport-cc"]
             },
             %{pt: "9", name: "G722", rate: 8000, channels: nil},
             %{pt: "0", name: "PCMU"},
             %{pt: "126", name: "telephone-event"}
           ] = WebRTC.codecs(audio)

    assert Enum.map(WebRTC.codecs(video), & &1.name) == ["VP8", "rtx", "H264", "rtx"]

    # Keeping H264 keeps its rtx, and removes the attributes of the others
    sdp2 = WebRTC.keep_codecs(sdp, "video", ["h264"])
    [audio2, video2] = sdp2.medias
    assert audio2 == audio
    assert video2.fmt == ["102", "103"]
    refute Enum.any?(video2.attributes, &match?({_, ["96" | _]}, &1))
    refute Enum.any?(video2.attributes, &match?({_, ["97" | _]}, &1))

    # Removing VP8 removes its rtx
    [_, video3] = WebRTC.remove_codecs(sdp, "video", ["VP8"]).medias
    assert video3.fmt == ["102", "103"]

    [audio4, _] = WebRTC.remove_codecs(sdp, "audio", ["opus", "G722"]).medias
    assert audio4.fmt == ["0", "126"]
    assert {:ok, _} = SDP.parse(SDP.encode(WebRTC.keep_codecs(sdp, "audio", ["PCMU"])))
  end
end
