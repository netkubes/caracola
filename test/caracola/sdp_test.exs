defmodule Caracola.SDPTest do
  use ExUnit.Case, async: true

  alias Caracola.SDP
  alias Caracola.SDP.Media

  doctest Caracola.SDP

  # Ported from nksip_sdp EUnit tests

  test "parse and encode a multimedia sdp" do
    bin =
      "v=0\r\n" <>
        "o=- 31726 1 IN IP4 130.117.91.40\r\n" <>
        "s=Duocom\r\n" <>
        "c=IN IP4 130.117.91.40\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 50370 RTP/AVP 0 101\r\n" <>
        "a=rtpmap:0 PCMU/8000\r\n" <>
        "a=rtpmap:101 telephone-event/8000\r\n" <>
        "a=rtcp:1500 IN IP4 1.2.3.4\r\n" <>
        "a=fmtp:101 0-15\r\n" <>
        "a=ptime:30\r\n" <>
        "a=sendrecv\r\n" <>
        "m=video 50371 RTP/AVP 0 101\r\n" <>
        "i=I2\r\n" <>
        "c=IN IP4 130.117.91.41\r\n" <>
        "a=rtcp:1500\r\n" <>
        "a=rtpmap:0\r\n" <>
        "a=rtpmap:101 telephone-event/8000\r\n" <>
        "a=fmtp:101 0-15\r\n" <>
        "a=ptime:30\r\n" <>
        "a=sendrecv\r\n" <>
        "a=otro\r\n" <>
        "a=uno:value otro:value\r\n"

    assert {:ok, sdp} = SDP.parse(bin)

    assert %SDP{
             sdp_vsn: "0",
             user: "-",
             id: 31_726,
             vsn: 1,
             address: {"IN", "IP4", "130.117.91.40"},
             session: "Duocom",
             connect: {"IN", "IP4", "130.117.91.40"},
             time: [{0, 0, []}],
             medias: [
               %Media{
                 media: "audio",
                 port: 50_370,
                 proto: "RTP/AVP",
                 fmt: ["0", "101"],
                 attributes: [
                   {"rtpmap", ["0", "PCMU/8000"]},
                   {"rtpmap", ["101", "telephone-event/8000"]},
                   {"rtcp", ["1500", "IN", "IP4", "1.2.3.4"]},
                   {"fmtp", ["101", "0-15"]},
                   {"ptime", ["30"]},
                   {"sendrecv", []}
                 ]
               },
               %Media{
                 media: "video",
                 port: 50_371,
                 fmt: ["0", "101"],
                 info: "I2",
                 connect: {"IN", "IP4", "130.117.91.41"},
                 attributes: [
                   {"rtcp", ["1500"]},
                   {"rtpmap", ["0"]},
                   {"rtpmap", ["101", "telephone-event/8000"]},
                   {"fmtp", ["101", "0-15"]},
                   {"ptime", ["30"]},
                   {"sendrecv", []},
                   {"otro", []},
                   {"uno", ["value", "otro:value"]}
                 ]
               }
             ]
           } = sdp

    assert SDP.encode(sdp) == bin
  end

  test "parse and encode all fields" do
    bin =
      "v=0\r\n" <>
        "o=Name 1 2 IN IP4 1.2.3.4\r\n" <>
        "s=S\r\n" <>
        "i=I\r\n" <>
        "u=U\r\n" <>
        "e=E\r\n" <>
        "p=P\r\n" <>
        "c=IN IP4 4.3.2.1\r\n" <>
        "b=B1\r\n" <>
        "b=B2\r\n" <>
        "t=1 2\r\n" <>
        "r=T1R1\r\n" <>
        "r=T1R2\r\n" <>
        "t=3 4\r\n" <>
        "r=T2R1\r\n" <>
        "r=T2R2\r\n" <>
        "z=Z\r\n" <>
        "k=K\r\n" <>
        "a=prea1\r\n" <>
        "a=prea2:value a2\r\n" <>
        "m=class0 1234 transp0 1 2 3\r\n" <>
        "i=M1I\r\n" <>
        "c=IN IP4 5.6.7.8\r\n" <>
        "b=M1B1\r\n" <>
        "b=M1B2\r\n" <>
        "k=M1K\r\n" <>
        "a=M1A1\r\n" <>
        "a=M1A2\r\n" <>
        "m=class2 4321/2 transp1\r\n"

    assert {:ok, sdp} = SDP.parse(bin)

    assert %SDP{
             user: "Name",
             id: 1,
             vsn: 2,
             address: {"IN", "IP4", "1.2.3.4"},
             session: "S",
             info: "I",
             uri: "U",
             email: "E",
             phone: "P",
             connect: {"IN", "IP4", "4.3.2.1"},
             bandwidth: ["B1", "B2"],
             time: [{1, 2, ["T1R1", "T1R2"]}, {3, 4, ["T2R1", "T2R2"]}],
             zone: "Z",
             key: "K",
             attributes: [{"prea1", []}, {"prea2", ["value", "a2"]}],
             medias: [
               %Media{
                 media: "class0",
                 port: 1234,
                 nports: 1,
                 proto: "transp0",
                 fmt: ["1", "2", "3"],
                 info: "M1I",
                 connect: {"IN", "IP4", "5.6.7.8"},
                 bandwidth: ["M1B1", "M1B2"],
                 key: "M1K",
                 attributes: [{"M1A1", []}, {"M1A2", []}]
               },
               %Media{media: "class2", port: 4321, nports: 2, proto: "transp1", fmt: []}
             ]
           } = sdp

    assert SDP.encode(sdp) == bin
  end

  test "new" do
    medias = [
      {"audio", 10_000, [{:rtpmap, 0, "Params0"}, {:rtpmap, 1, "Params1"}, :sendrecv]},
      {"video", 10_001, [{:rtpmap, 2, "Params2"}, {:rtpmap, 3, "Params3"}, :sendrecv]}
    ]

    %SDP{id: id, vsn: vsn} = sdp = SDP.new("local", medias)

    assert to_string(sdp) ==
             "v=0\r\n" <>
               "o=- #{id} #{vsn} IN IP4 local\r\n" <>
               "s=-\r\n" <>
               "c=IN IP4 local\r\n" <>
               "t=0 0\r\n" <>
               "m=audio 10000 RTP/AVP 0 1\r\n" <>
               "a=rtpmap:0 Params0\r\n" <>
               "a=rtpmap:1 Params1\r\n" <>
               "a=sendrecv\r\n" <>
               "m=video 10001 RTP/AVP 2 3\r\n" <>
               "a=rtpmap:2 Params2\r\n" <>
               "a=rtpmap:3 Params3\r\n" <>
               "a=sendrecv\r\n"

    assert %SDP{address: {"IN", "IP6", "::1"}} = SDP.new("::1")
  end

  test "minimal sdp" do
    sdp = %SDP{connect: {"IN", "IP4", "0.0.0.0"}, time: [{0, 0, []}]}
    bin = "v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=-\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\n"
    assert SDP.encode(sdp) == bin
    assert SDP.parse(bin) == {:ok, sdp}
  end

  test "lf line endings, freeswitch b= among a= and empty attribute values" do
    bin =
      "v=0\n" <>
        "o=- 3680359967 3680359967 IN IP4 0.0.0.0\n" <>
        "s=Kurento Media Server\n" <>
        "c=IN IP4 0.0.0.0\n" <>
        "t=0 0\n" <>
        "a=msid-semantic: WMS FunlozxAX\n" <>
        "a=group:BUNDLE audio video\n" <>
        "m=video 1 UDP/TLS/RTP/SAVPF 100\n" <>
        "a=mid:video\n" <>
        "b=AS:500\n" <>
        "a=rtcp-fb:100 nack pli\n"

    assert {:ok, sdp} = SDP.parse(bin)
    assert {"msid-semantic", ["", "WMS", "FunlozxAX"]} in sdp.attributes

    assert [%Media{bandwidth: ["AS:500"], attributes: [_, {"rtcp-fb", ["100", "nack", "pli"]}]}] =
             sdp.medias

    # b= is moved back to its place
    assert SDP.encode(sdp) ==
             bin
             |> String.replace("a=mid:video\nb=AS:500\n", "b=AS:500\na=mid:video\n")
             |> String.replace("\n", "\r\n")
  end

  test "invalid sdps" do
    for bad <- [
          "",
          "v=0\r\n",
          "v=0\r\no=- 1 IN IP4 h\r\ns=-\r\n",
          "v=0\r\no=- a 1 IN IP4 h\r\ns=-\r\n",
          "v=0\r\no=- 1 1 IN IP4 h\r\ns=-\r\nc=IN IP4\r\n",
          "v=0\r\no=- 1 1 IN IP4 h\r\ns=-\r\nm=audio x RTP/AVP 0\r\n",
          "v=0\r\no=- 1 1 IN IP4 h\r\ns=-\r\nm=audio\r\n",
          "v=0\r\no=- 1 1 IN IP4 h\r\ns=-\r\nt=0 0\r\nv=0\r\n"
        ] do
      assert SDP.parse(bad) == :error, "expected error for #{inspect(bad)}"
    end
  end

  test "update and versions" do
    sdp = SDP.new("h", [{"audio", 1, [{:rtpmap, 0, "PCMU/8000"}, :sendrecv, "ptime:20"]}])
    sdp2 = SDP.update(sdp, :inactive)
    assert sdp2.vsn == sdp.vsn + 1

    assert hd(sdp2.medias).attributes == [
             {"rtpmap", ["0", "PCMU/8000"]},
             {"ptime", ["20"]},
             {"inactive", []}
           ]

    assert SDP.newer?(sdp2, sdp)
    refute SDP.newer?(sdp, sdp2)
    refute SDP.newer?(sdp, sdp)
    refute SDP.newer?(nil, sdp)
  end
end
