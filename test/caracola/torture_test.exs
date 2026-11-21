defmodule Caracola.TortureTest do
  # Messages are raw wire bytes, kept as in RFC 4475
  # credo:disable-for-this-file Credo.Check.Readability.StringSigils

  @moduledoc """
  RFC 4475 "SIP Torture Test Messages", ported from NkSIP's `t05_torture1`,
  `t06_torture2` and the parser-level cases of `t07_torture3`.

  NkSIP's tests that sent the message to a running server and checked the
  `400 Invalid <header>` reply are checked here against `Caracola.Parser`
  and `Caracola.Serializer.error_response/1`.
  """
  use ExUnit.Case, async: true

  alias Caracola.{Message, ParseError, Parser, SDP, Serializer, Tokens, URI, Via}

  @sdp_150 "v=0\r\n" <>
             "o=mhandley 29739 7272939 IN IP4 192.0.2.1\r\n" <>
             "s=-\r\n" <>
             "c=IN IP4 192.0.2.1\r\n" <>
             "t=0 0\r\n" <>
             "m=audio 49217 RTP/AVP 0 12\r\n" <>
             "m=video 3227 RTP/AVP 31\r\n" <>
             "a=rtpmap:31 LPC\r\n"

  defp parse(msg, transport \\ :udp) do
    case Parser.parse(msg, transport) do
      {:ok, sip_msg, ""} -> sip_msg
      {:ok, sip_msg, rest} -> {:tail, sip_msg, rest}
      :partial -> :partial
      {:error, %ParseError{reason: reason}} -> {:error, reason}
    end
  end

  # First line of the reply NkSIP's server would send
  defp reply(msg, transport) do
    assert {:error, error} = Parser.parse(msg, transport)
    assert {:ok, reply} = Serializer.error_response(error)
    [line | _] = String.split(reply, "\r\n")
    line
  end

  ## ===================================================================
  ## 3.1.1 Valid messages
  ## ===================================================================

  # 3.1.1.1 A Short Tortuous INVITE
  test "valid 1: wsinv" do
    msg =
      "INVITE sip:vivekg@chair-dnrc.example.com;unknownparam SIP/2.0\r\n" <>
        "TO :\r\n" <>
        " sip:vivekg@chair-dnrc.example.com ;   tag    = 1918181833n\r\n" <>
        "from   : \"J Rosenberg \\\\\\\"\"       <sip:jdrosen@example.com>\r\n" <>
        " ;\r\n" <>
        " tag = 98asjd8\r\n" <>
        "MaX-fOrWaRdS: 0068\r\n" <>
        "Call-ID: wsinv.ndaksdj@192.0.2.1\r\n" <>
        "Content-Length   : 150\r\n" <>
        "cseq: 0009\r\n" <>
        " INVITE\r\n" <>
        "Via  : SIP  /   2.0\r\n" <>
        " /UDP\r\n" <>
        "    192.0.2.2;branch=390skdjuw\r\n" <>
        "s :\r\n" <>
        "NewFangledHeader:   newfangled value\r\n" <>
        " continued newfangled value\r\n" <>
        "UnknownHeaderWithUnusualValue: ;;,,;;,;\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Route:\r\n" <>
        " <sip:services.example.com;lr;unknownwith=value;unknown-no-value>\r\n" <>
        "v:  SIP  / 2.0  / TCP     spindle.example.com   ;\r\n" <>
        "  branch  =   z9hG4bK9ikj8  ,\r\n" <>
        " SIP  /    2.0   / UDP  192.168.255.111   ; branch=\r\n" <>
        " z9hG4bK30239\r\n" <>
        "m:\"Quoted string \\\"\\\"\" <sip:jdrosen@example.com> ; newparam =\r\n" <>
        "      newvalue ;\r\n" <>
        "    secondparam ; q = 0.33\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.3\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.4\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert %Message{
             class: {:req, :invite},
             ruri: %URI{
               user: "vivekg",
               domain: "chair-dnrc.example.com",
               port: nil,
               params: [{"unknownparam", nil}]
             },
             to: %URI{
               user: "vivekg",
               domain: "chair-dnrc.example.com",
               ext_params: [{"tag", "1918181833n"}]
             },
             to_tag: "1918181833n",
             from: %URI{
               disp: ~S("J Rosenberg \\\""),
               user: "jdrosen",
               domain: "example.com",
               ext_params: [{"tag", "98asjd8"}]
             },
             from_tag: "98asjd8",
             max_forwards: 68,
             call_id: "wsinv.ndaksdj@192.0.2.1",
             cseq: {9, :invite},
             vias: [
               %Via{
                 transport: :udp,
                 domain: "192.0.2.2",
                 port: nil,
                 params: [{"branch", "390skdjuw"}]
               },
               %Via{
                 transport: :tcp,
                 domain: "spindle.example.com",
                 params: [{"branch", "z9hG4bK9ikj8"}]
               },
               %Via{
                 transport: :udp,
                 domain: "192.168.255.111",
                 params: [{"branch", "z9hG4bK30239"}]
               }
             ],
             content_type: {"application/sdp", []},
             routes: [
               %URI{
                 user: nil,
                 domain: "services.example.com",
                 params: [{"lr", nil}, {"unknownwith", "value"}, {"unknown-no-value", nil}]
               }
             ],
             contacts: [
               %URI{
                 disp: ~S("Quoted string \"\""),
                 user: "jdrosen",
                 domain: "example.com",
                 params: [],
                 ext_params: [{"newparam", "newvalue"}, {"secondparam", nil}, {"q", "0.33"}]
               }
             ],
             headers: [
               {"subject", ""},
               {"newfangledheader", "newfangled value continued newfangled value"},
               {"unknownheaderwithunusualvalue", ";;,,;;,;"}
             ],
             body: "v=0\r\n" <> _
           } = parse(msg)
  end

  # 3.1.1.2 Wide Range of Valid Characters
  test "valid 2: intmeth" do
    method = "!interesting-Method0123456789_*+`.%indeed'~"

    msg =
      "!interesting-Method0123456789_*+`.%indeed'~ sip:1_unusual.URI~(to-be!sure)&isn't+it$/crazy?,/;;*:&it+has=1,weird!*pas$wo~d_too.(doesn't-it)@example.com SIP/2.0\r\n" <>
        "Via: SIP/2.0/TCP host1.example.com;branch=z9hG4bK-.!%66*_+`'~\r\n" <>
        "To: \"BEL:\\\x07 NUL:\\\x00 DEL:\\\x7F\" <sip:1_unusual.URI~(to-be!sure)&isn't+it$/crazy?,/;;*@example.com>\r\n" <>
        "From: token1~` token2'+_ token3*%!.- <sip:mundane@example.com> ;fromParam''~+*_!.-%=" <>
        "\xD1\x80\xD0\xB0\xD0\xB1\xD0\xBE\xD1\x82\xD0\xB0\xD1\x8E\xD1\x89\xD0\xB8\xD0\xB9" <>
        ";tag=_token~1'+`*%!-.\r\n" <>
        "Call-ID: intmeth.word%ZK-!.*_+'@word`~)(><:\\/\"][?}{\r\n" <>
        "CSeq: 139122385 !interesting-Method0123456789_*+`.%indeed'~\r\n" <>
        "Max-Forwards: 255\r\n" <>
        "extensionHeader-!.%*+_`'~:\xEF\xBB\xBF\xE5\xA4\xA7\xE5\x81\x9C\xE9\x9B\xBB\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n"

    l1 = "\xD1\x80\xD0\xB0\xD0\xB1\xD0\xBE\xD1\x82\xD0\xB0\xD1\x8E\xD1\x89\xD0\xB8\xD0\xB9"
    l2 = "\"BEL:\\\x07 NUL:\\\x00 DEL:\\\x7F\""
    l3 = "\xEF\xBB\xBF\xE5\xA4\xA7\xE5\x81\x9C\xE9\x9B\xBB"
    user = "1_unusual.URI~(to-be!sure)&isn't+it$/crazy?,/;;*"

    assert %Message{
             class: {:req, ^method},
             ruri: %URI{
               scheme: :sip,
               user: ^user,
               pass: "&it+has=1,weird!*pas$wo~d_too.(doesn't-it)",
               domain: "example.com",
               port: nil
             },
             vias: [
               %Via{
                 transport: :tcp,
                 domain: "host1.example.com",
                 params: [{"branch", "z9hG4bK-.!%66*_+`'~"}]
               }
             ],
             to: %URI{disp: ^l2, user: ^user, pass: nil, domain: "example.com", params: []},
             to_tag: nil,
             from: %URI{
               disp: "token1~` token2'+_ token3*%!.-",
               user: "mundane",
               domain: "example.com",
               ext_params: [{"fromParam''~+*_!.-%", ^l1}, {"tag", "_token~1'+`*%!-."}]
             },
             from_tag: "_token~1'+`*%!-.",
             call_id: "intmeth.word%ZK-!.*_+'@word`~)(><:\\/\"][?}{",
             cseq: {139_122_385, ^method},
             max_forwards: 255,
             headers: [{"extensionheader-!.%*+_`'~", ^l3}]
           } = parse(msg)
  end

  # 3.1.1.3 Valid Use of the % Escaping Mechanism
  test "valid 3: esc01" do
    msg =
      "INVITE sip:sips%3Auser%40example.com@example.net SIP/2.0\r\n" <>
        "To: sip:%75se%72@example.com\r\n" <>
        "From: <sip:I%20have%20spaces@example.net>;tag=938\r\n" <>
        "Max-Forwards: 87\r\n" <>
        "i: esc01.239409asdfakjkn23onasd0-3234\r\n" <>
        "CSeq: 234234 INVITE\r\n" <>
        "Via: SIP/2.0/UDP host5.example.net;branch=z9hG4bKkdjuw\r\n" <>
        "C: application/sdp\r\n" <>
        "Contact:\r\n" <>
        "    <sip:cal%6Cer@host5.example.net;%6C%72;n%61me=v%61lue%25%34%31>\r\n" <>
        "Content-Length: 150\r\n" <>
        "\r\n" <>
        @sdp_150

    assert %Message{
             ruri: %URI{user: "sips%3Auser%40example.com", pass: nil, domain: "example.net"},
             to: %URI{user: "%75se%72", domain: "example.com"},
             from: %URI{
               user: "I%20have%20spaces",
               domain: "example.net",
               ext_params: [{"tag", "938"}]
             },
             call_id: "esc01.239409asdfakjkn23onasd0-3234",
             content_type: {"application/sdp", []},
             contacts: [
               %URI{
                 disp: nil,
                 user: "cal%6Cer",
                 domain: "host5.example.net",
                 params: [{"%6C%72", nil}, {"n%61me", "v%61lue%25%34%31"}]
               }
             ]
           } = parse(msg)
  end

  # 3.1.1.4 Escaped Nulls in URIs
  test "valid 4: escnull" do
    msg =
      "REGISTER sip:example.com SIP/2.0\r\n" <>
        "To: sip:null-%00-null@example.com\r\n" <>
        "From: sip:null-%00-null@example.com;tag=839923423\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Call-ID: escnull.39203ndfvkjdasfkq3w4otrq0adsfdfnavd\r\n" <>
        "CSeq: 14398234 REGISTER\r\n" <>
        "Via: SIP/2.0/UDP host5.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "Contact: <sip:%00@host5.example.com>\r\n" <>
        "Contact: <sip:%00%00@host5.example.com>\r\n" <>
        "L:0\r\n" <>
        "\r\n"

    assert %Message{
             class: {:req, :register},
             to: %URI{user: "null-%00-null", domain: "example.com"},
             from: %URI{
               user: "null-%00-null",
               domain: "example.com",
               ext_params: [{"tag", "839923423"}]
             },
             contacts: [
               %URI{user: "%00", domain: "host5.example.com"},
               %URI{user: "%00%00", domain: "host5.example.com"}
             ],
             body: ""
           } = parse(msg)
  end

  # 3.1.1.5 Use of % When It Is Not an Escape
  test "valid 5: esc02" do
    msg =
      "RE%47IST%45R sip:registrar.example.com SIP/2.0\r\n" <>
        "To: \"%Z%45\" <sip:resource@example.com>\r\n" <>
        "From: \"%Z%45\" <sip:resource@example.com>;tag=f232jadfj23\r\n" <>
        "Call-ID: esc02.asdfnqwo34rq23i34jrjasdcnl23nrlknsdf\r\n" <>
        "Via: SIP/2.0/TCP host.example.com;branch=z9hG4bK209%fzsnel234\r\n" <>
        "CSeq: 29344 RE%47IST%45R\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Contact: <sip:alias1@host1.example.com>\r\n" <>
        "C%6Fntact: <sip:alias2@host2.example.com>\r\n" <>
        "Contact: <sip:alias3@host3.example.com>\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert %Message{
             class: {:req, "RE%47IST%45R"},
             cseq: {29_344, "RE%47IST%45R"},
             ruri: %URI{domain: "registrar.example.com"},
             to: %URI{disp: ~S("%Z%45"), user: "resource", pass: nil, domain: "example.com"},
             from: %URI{disp: ~S("%Z%45"), user: "resource", ext_params: [{"tag", "f232jadfj23"}]},
             contacts: [
               %URI{user: "alias1", domain: "host1.example.com"},
               %URI{user: "alias3", domain: "host3.example.com"}
             ],
             headers: [{"c%6fntact", "<sip:alias2@host2.example.com>"}]
           } = parse(msg)
  end

  # 3.1.1.6 Message with No LWS between Display Name and <
  test "valid 6: lwsdisp" do
    msg =
      "OPTIONS sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: caller<sip:caller@example.com>;tag=323\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Call-ID: lwsdisp.1234abcd@funky.example.com\r\n" <>
        "CSeq: 60 OPTIONS\r\n" <>
        "Via: SIP/2.0/UDP funky.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert %Message{
             from: %URI{
               disp: "caller",
               scheme: :sip,
               user: "caller",
               pass: nil,
               domain: "example.com",
               port: nil,
               params: [],
               headers: [],
               ext_params: [{"tag", "323"}],
               ext_headers: []
             }
           } = parse(msg)
  end

  # 3.1.1.7 Long Values in Header Fields
  test "valid 7: longreq" do
    long_disp =
      "\"I have a user name of extreme extreme extreme extreme extreme extreme extreme extreme extreme extreme proportion\""

    long_user =
      "amazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallername"

    long_tag =
      "12982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982424"

    vias =
      for(n <- 33..1//-1, do: "Via: SIP/2.0/TCP sip#{n}.example.com\r\n")
      |> List.replace_at(1, "v: SIP/2.0/TCP sip32.example.com\r\n")
      |> List.replace_at(2, "V: SIP/2.0/TCP sip31.example.com\r\n")
      |> List.replace_at(4, "ViA: SIP/2.0/TCP sip29.example.com\r\n")
      |> List.replace_at(5, "VIa: SIP/2.0/TCP sip28.example.com\r\n")
      |> List.replace_at(6, "VIA: SIP/2.0/TCP sip27.example.com\r\n")
      |> List.replace_at(7, "via: SIP/2.0/TCP sip26.example.com\r\n")
      |> List.replace_at(8, "viA: SIP/2.0/TCP sip25.example.com\r\n")
      |> List.replace_at(9, "vIa: SIP/2.0/TCP sip24.example.com\r\n")
      |> List.replace_at(10, "vIA: SIP/2.0/TCP sip23.example.com\r\n")
      |> List.replace_at(11, "V :  SIP/2.0/TCP sip22.example.com\r\n")
      |> List.replace_at(12, "v :  SIP/2.0/TCP sip21.example.com\r\n")
      |> List.replace_at(13, "V  : SIP/2.0/TCP sip20.example.com\r\n")
      |> List.replace_at(14, "v  : SIP/2.0/TCP sip19.example.com\r\n")
      |> List.replace_at(15, "Via : SIP/2.0/TCP sip18.example.com\r\n")
      |> List.replace_at(16, "Via  : SIP/2.0/TCP sip17.example.com\r\n")
      |> Enum.join()

    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "To: #{long_disp} <sip:user@example.com:6000;unknownparam1=verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongvalue;longparamnamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamename=shortvalue;verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongParameterNameWithNoValue>\r\n" <>
        "F: sip:#{long_user}@example.net;tag=#{long_tag};unknownheaderparamnamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamename=unknowheaderparamvaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue;unknownValuelessparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamname\r\n" <>
        "Call-ID: longreq.onereallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallylongcallid\r\n" <>
        "CSeq: 3882340 INVITE\r\n" <>
        "Unknown-LongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLong-Name:unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-value;unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-parameter-name =unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-parameter-value\r\n" <>
        vias <>
        "Via: SIP/2.0/TCP host.example.com;received=192.0.2.5;branch=verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongbranchvalue\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Contact: <sip:#{long_user}@host5.example.net>\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "l: 150\r\n" <>
        "\r\n" <>
        @sdp_150

    assert %Message{
             to: %URI{
               disp: ^long_disp,
               user: "user",
               domain: "example.com",
               port: 6000,
               params: [
                 {"unknownparam1",
                  "verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongvalue"},
                 {"longparamnamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamename",
                  "shortvalue"},
                 {"verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongParameterNameWithNoValue",
                  nil}
               ]
             },
             to_tag: nil,
             from: %URI{
               user: ^long_user,
               domain: "example.net",
               params: [],
               ext_params: [
                 {"tag", ^long_tag},
                 {"unknownheaderparamnamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamename",
                  "unknowheaderparamvaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue"},
                 {"unknownValuelessparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamname",
                  nil}
               ]
             },
             from_tag: ^long_tag,
             cseq: {3_882_340, :invite},
             contacts: [%URI{user: ^long_user, domain: "host5.example.net"}],
             headers: [
               {"unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-name",
                header}
             ],
             vias: vias
           } = parse(msg)

    assert length(vias) == 34
    assert Enum.all?(vias, &(&1.transport == :tcp))

    assert Enum.map(vias, & &1.domain) ==
             Enum.map(33..1//-1, &"sip#{&1}.example.com") ++ ["host.example.com"]

    assert [%Via{params: [{"received", "192.0.2.5"}, {"branch", "verylong" <> _}]}] =
             Enum.take(vias, -1)

    assert {:ok,
            [
              {"unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-value",
               [
                 {"unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-parameter-name",
                  "unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-parameter-value"}
               ]}
            ]} = Tokens.parse(header)
  end

  # 3.1.1.8 Extra Trailing Octets in a UDP Datagram
  test "valid 8: dblreq" do
    msg =
      "REGISTER sip:example.com SIP/2.0\r\n" <>
        "To: sip:j.user@example.com\r\n" <>
        "From: sip:j.user@example.com;tag=43251j3j324\r\n" <>
        "Max-Forwards: 8\r\n" <>
        "I: dblreq.0ha0isndaksdj99sdfafnl3lk233412\r\n" <>
        "Contact: sip:j.user@host.example.com\r\n" <>
        "CSeq: 8 REGISTER\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.125;branch=z9hG4bKkdjuw23492\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n" <>
        "INVITE sip:joe@example.com SIP/2.0\r\n" <>
        "t: sip:joe@example.com\r\n" <>
        "From: sip:caller@example.net;tag=141334\r\n" <>
        "Max-Forwards: 8\r\n" <>
        "Call-ID: dblreq.0ha0isnda977644900765@192.0.2.15\r\n" <>
        "CSeq: 8 INVITE\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.15;branch=z9hG4bKkdjuw380234\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 150\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.15\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.15\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m =video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert {:tail, %Message{class: {:req, :register}, body: ""}, "INVITE " <> _} = parse(msg)
  end

  # 3.1.1.9 Semicolon-Separated Parameters in URI User Part
  test "valid 9: semiuri" do
    msg =
      "OPTIONS sip:user;par=u%40example.net@example.com SIP/2.0\r\n" <>
        "To: sip:j_user@example.com\r\n" <>
        "From: sip:caller@example.org;tag=33242\r\n" <>
        "Max-Forwards: 3\r\n" <>
        "Call-ID: semiuri.0ha0isndaksdj\r\n" <>
        "CSeq: 8 OPTIONS\r\n" <>
        "Accept: application/sdp, application/pkcs7-mime,\r\n" <>
        "  multipart/mixed, multipart/signed,\r\n" <>
        "  message/sip, message/sipfrag\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bKkdjuw\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert %Message{
             ruri: %URI{user: "user;par=u%40example.net", pass: nil, domain: "example.com"},
             to: %URI{disp: nil, user: "j_user", domain: "example.com"},
             from: %URI{
               disp: nil,
               user: "caller",
               domain: "example.org",
               ext_params: [{"tag", "33242"}]
             },
             headers: [{"accept", accept}]
           } = parse(msg)

    assert Tokens.parse(accept) ==
             {:ok,
              [
                {"application/sdp", []},
                {"application/pkcs7-mime", []},
                {"multipart/mixed", []},
                {"multipart/signed", []},
                {"message/sip", []},
                {"message/sipfrag", []}
              ]}
  end

  # 3.1.1.10 Varied and Unknown Transport Types
  test "valid 10: transports" do
    msg =
      "OPTIONS sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: <sip:caller@example.com>;tag=323\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Call-ID:  transports.kijh4akdnaqjkwendsasfdj\r\n" <>
        "Accept: application/sdp\r\n" <>
        "CSeq: 60 OPTIONS\r\n" <>
        "Via: SIP/2.0/UDP t1.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "Via: SIP/2.0/SCTP t2.example.com;branch=z9hG4bKklasjdhf\r\n" <>
        "Via: SIP/2.0/TLS t3.example.com;branch=z9hG4bK2980unddj\r\n" <>
        "Via: SIP/2.0/UNKNOWN t4.example.com;branch=z9hG4bKasd0f3en\r\n" <>
        "Via: SIP/2.0/TCP t5.example.com;branch=z9hG4bK0a9idfnee\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert %Message{
             call_id: "transports.kijh4akdnaqjkwendsasfdj",
             vias: [
               %Via{
                 transport: :udp,
                 domain: "t1.example.com",
                 port: nil,
                 params: [{"branch", "z9hG4bKkdjuw"}]
               },
               %Via{
                 transport: :sctp,
                 domain: "t2.example.com",
                 params: [{"branch", "z9hG4bKklasjdhf"}]
               },
               %Via{
                 transport: :tls,
                 domain: "t3.example.com",
                 params: [{"branch", "z9hG4bK2980unddj"}]
               },
               %Via{
                 transport: "UNKNOWN",
                 domain: "t4.example.com",
                 params: [{"branch", "z9hG4bKasd0f3en"}]
               },
               %Via{
                 transport: :tcp,
                 domain: "t5.example.com",
                 params: [{"branch", "z9hG4bK0a9idfnee"}]
               }
             ]
           } = parse(msg)
  end

  # 3.1.1.11 Multipart MIME Message
  test "valid 11: mpart01" do
    body =
      "--7a9cbec02ceef655\r\n" <>
        "Content-Type: text/plain\r\n" <>
        "Content-Transfer-Encoding: binary\r\n" <>
        "\r\n" <>
        "Hello\r\n" <>
        "--7a9cbec02ceef655\r\n" <>
        "Content-Type: application/octet-stream\r\n" <>
        "Content-Transfer-Encoding: binary\r\n" <>
        "\r\n" <>
        "\x30\x82\x01\x52\x06\x09\x2A\x86\r\n" <>
        "\x48\x86\xF7\x0D\x01\x07\x02\xA0\x82\x01\x43\x30\x82\x01\x3F\x02" <>
        "\x01\x01\x31\x09\x30\x07\x06\x05\x2B\x0E\x03\x02\x1A\x30\x0B\x06" <>
        "\x09\x2A\x86\x48\x86\xF7\x0D\x01\x07\x01\x31\x82\x01\x20\x30\x82" <>
        "\x01\x1C\x02\x01\x01\x30\x7C\x30\x70\x31\x0B\x30\x09\x06\x03\x55" <>
        "\x04\x06\x13\x02\x55\x53\x31\x13\x30\x11\x06\x03\x55\x04\x08\x13" <>
        "\x0A\x43\x61\x6C\x69\x66\x6F\x72\x6E\x69\x61\x31\x11\x30\x0F\x06" <>
        "\x03\x55\x04\x07\x13\x08\x53\x61\x6E\x20\x4A\x6F\x73\x65\x31\x0E" <>
        "\x30\x0C\x06\x03\x55\x04\x0A\x13\x05\x73\x69\x70\x69\x74\x31\x29" <>
        "\x30\x27\x06\x03\x55\x04\x0B\x13\x20\x53\x69\x70\x69\x74\x20\x54" <>
        "\x65\x73\x74\x20\x43\x65\x72\x74\x69\x66\x69\x63\x61\x74\x65\x20" <>
        "\x41\x75\x74\x68\x6F\x72\x69\x74\x79\x02\x08\x01\x95\x00\x71\x02" <>
        "\x33\x01\x13\x30\x07\x06\x05\x2B\x0E\x03\x02\x1A\x30\x0D\x06\x09" <>
        "\x2A\x86\x48\x86\xF7\x0D\x01\x01\x01\x05\x00\x04\x81\x80\x8E\xF4" <>
        "\x66\xF9\x48\xF0\x52\x2D\xD2\xE5\x97\x8E\x9D\x95\xAA\xE9\xF2\xFE" <>
        "\x15\xA0\x66\x59\x71\x62\x92\xE8\xDA\x2A\xA8\xD8\x35\x0A\x68\xCE" <>
        "\xFF\xAE\x3C\xBD\x2B\xFF\x16\x75\xDD\xD5\x64\x8E\x59\x3D\xD6\x47" <>
        "\x28\xF2\x62\x20\xF7\xE9\x41\x74\x9E\x33\x0D\x9A\x15\xED\xAB\xDB" <>
        "\x93\xD1\x0C\x42\x10\x2E\x7B\x72\x89\xD2\x9C\xC0\xC9\xAE\x2E\xFB" <>
        "\xC7\xC0\xCF\xF9\x17\x2F\x3B\x02\x7E\x4F\xC0\x27\xE1\x54\x6D\xE4" <>
        "\xB6\xAA\x3A\xBB\x3E\x66\xCC\xCB\x5D\xD6\xC6\x4B\x83\x83\x14\x9C" <>
        "\xB8\xE6\xFF\x18\x2D\x94\x4F\xE5\x7B\x65\xBC\x99\xD0\x05" <>
        "--7a9cbec02ceef655--\r\n"

    msg =
      "MESSAGE sip:kumiko@example.org SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bK-d87543-4dade06d0bdb11ee-1--d87543-;rport\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Route: <sip:127.0.0.1:5080>\r\n" <>
        "Identity: r5mwreLuyDRYBi/0TiPwEsY3rEVsk/G2WxhgTV1PF7hHuLIK0YWVKZhKv9Mj8UeXqkMVbnVq37CD+813gvYjcBUaZngQmXc9WNZSDNGCzA+fWl9MEUHWIZo1CeJebdY/XlgKeTa0Olvq0rt70Q5jiSfbqMJmQFteeivUhkMWYUA=\r\n" <>
        "Contact: <sip:fluffy@127.0.0.1:5070>\r\n" <>
        "To: <sip:kumiko@example.org>\r\n" <>
        "From: <sip:fluffy@example.com>;tag=2fb0dcc9\r\n" <>
        "Call-ID: 3d9485ad0c49859b@Zmx1ZmZ5LW1hYy0xNi5sb2NhbA..\r\n" <>
        "CSeq: 1 MESSAGE\r\n" <>
        "Content-Transfer-Encoding: binary\r\n" <>
        "Content-Type: multipart/mixed;boundary=7a9cbec02ceef655\r\n" <>
        "Date: Sat, 15 Oct 2005 04:44:56 GMT\r\n" <>
        "User-Agent: SIPimp.org/0.2.5 (curses)\r\n" <>
        "Content-Length: 553\r\n" <>
        "\r\n" <> body

    assert byte_size(body) == 553

    assert %Message{
             class: {:req, :message},
             vias: [
               %Via{
                 transport: :udp,
                 domain: "127.0.0.1",
                 port: 5070,
                 params: [
                   {"branch", "z9hG4bK-d87543-4dade06d0bdb11ee-1--d87543-"},
                   {"rport", nil}
                 ]
               }
             ],
             routes: [%URI{scheme: :sip, user: nil, pass: nil, domain: "127.0.0.1", port: 5080}],
             headers: [
               {"identity", "r5mwreLuyDRYBi" <> _},
               {"content-transfer-encoding", "binary"},
               {"date", "Sat, 15 Oct 2005 04:44:56 GMT"},
               {"user-agent", "SIPimp.org/0.2.5 (curses)"}
             ],
             content_type: {"multipart/mixed", [{"boundary", "7a9cbec02ceef655"}]},
             body: ^body
           } = parse(msg)
  end

  # 3.1.1.12 Unusual Reason Phrase
  test "valid 12: unreason" do
    reason =
      "= 2**3 * 5**2 \xD0\xBD\xD0\xBE\x20\xD1\x81\xD1\x82\xD0\xBE\x20\xD0\xB4\xD0\xB5\xD0\xB2\xD1\x8F\xD0\xBD\xD0\xBE\xD1\x81\xD1\x82\xD0\xBE\x20\xD0\xB4\xD0\xB5\xD0\xB2\xD1\x8F\xD1\x82\xD1\x8C\x20\x2D\x20\xD0\xBF\xD1\x80\xD0\xBE\xD1\x81\xD1\x82\xD0\xBE\xD0\xB5"

    msg =
      "SIP/2.0 200 " <>
        reason <>
        "\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.198;branch=z9hG4bK1324923\r\n" <>
        "Call-ID: unreason.1234ksdfak3j2erwedfsASdf\r\n" <>
        "CSeq: 35 INVITE\r\n" <>
        "From: sip:user@example.com;tag=11141343\r\n" <>
        "To: sip:user@example.edu;tag=2229\r\n" <>
        "Content-Length: 154\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Contact: <sip:user@host198.example.com>\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.198\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.198\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert %Message{class: {:resp, 200, ^reason}, ruri: nil, cseq: {35, :invite}, to_tag: "2229"} =
             parse(msg)
  end

  # 3.1.1.13 Empty Reason Phrase
  test "valid 13: noreason" do
    msg =
      "SIP/2.0 100\x20\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.105;branch=z9hG4bK2398ndaoe\r\n" <>
        "Call-ID: noreason.asndj203insdf99223ndf\r\n" <>
        "CSeq: 35 INVITE\r\n" <>
        "From: <sip:user@example.com>;tag=39ansfi3\r\n" <>
        "To: <sip:user@example.edu>;tag=902jndnke3\r\n" <>
        "Content-Length: 0\r\n" <>
        "Contact: <sip:user@host105.example.com>\r\n" <>
        "\r\n"

    assert %Message{class: {:resp, 100, ""}} = parse(msg)
  end

  ## ===================================================================
  ## 3.1.2 Invalid messages
  ## ===================================================================

  # 3.1.2.1 Extraneous Header Field Separators
  test "invalid 1: badinv01" do
    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:j.user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=134161461246\r\n" <>
        "Max-Forwards: 7\r\n" <>
        "Call-ID: badinv01.0ha0isndaksdjasdf3234nas\r\n" <>
        "CSeq: 8 INVITE\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.15;;,;,,\r\n" <>
        "Contact: \"Joe\" <sip:joe@example.org>;;;;\r\n" <>
        "Content-Length: 152\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.15\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.15\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert reply(msg, :tcp) == "SIP/2.0 400 Invalid Via"
  end

  # 3.1.2.2 Content Length Larger Than Message
  test "invalid 2: clerr" do
    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "Max-Forwards: 80\r\n" <>
        "To: sip:j.user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=93942939o2\r\n" <>
        "Contact: <sip:caller@hungry.example.net>\r\n" <>
        "Call-ID: clerr.0ha0isndaksdjweiafasdk3\r\n" <>
        "CSeq: 8 INVITE\r\n" <>
        "Via: SIP/2.0/UDP host5.example.com;branch=z9hG4bK-39234-23523\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 9999\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.155\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.155\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert reply(msg, :udp) == "SIP/2.0 400 Invalid Content-Length"
    # On stream transports we just wait for more data
    assert parse(msg, :tcp) == :partial
  end

  # 3.1.2.3 Negative Content-Length
  test "invalid 3: ncl" do
    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "Max-Forwards: 254\r\n" <>
        "To: sip:j.user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=32394234\r\n" <>
        "Call-ID: ncl.0ha0isndaksdj2193423r542w35\r\n" <>
        "CSeq: 0 INVITE\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.53;branch=z9hG4bKkdjuw\r\n" <>
        "Contact: <sip:caller@example53.example.net>\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: -999\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.53\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.53\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert reply(msg, :tcp) == "SIP/2.0 400 Invalid Content-Length"
  end

  # 3.1.2.4 Request Scalar Fields with Overlarge Values
  test "invalid 4: scalar02" do
    msg =
      "REGISTER sip:example.com SIP/2.0\r\n" <>
        "Via: SIP/2.0/TCP host129.example.com;branch=z9hG4bK342sdfoi3\r\n" <>
        "To: <sip:user@example.com>\r\n" <>
        "From: <sip:user@example.com>;tag=239232jh3\r\n" <>
        "CSeq: 36893488147419103232 REGISTER\r\n" <>
        "Call-ID: scalar02.23o0pd9vanlq3wnrlnewofjas9ui32\r\n" <>
        "Max-Forwards: 300\r\n" <>
        "Expires: 1<repeat count=100>0</repeat>\r\n" <>
        "Contact: <sip:user@host129.example.com>\r\n" <>
        "  ;expires=280297596632815\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n"

    assert reply(msg, :tcp) == "SIP/2.0 400 Invalid CSeq"
  end

  # 3.1.2.5 Response Scalar Fields with Overlarge Values
  test "invalid 5: scalarlg" do
    msg =
      "SIP/2.0 503 Service Unavailable\r\n" <>
        "Via: SIP/2.0/TCP host129.example.com;branch=z9hG4bKzzxdiwo34sw;received=192.0.2.129\r\n" <>
        "To: <sip:user@example.com>\r\n" <>
        "From: <sip:other@example.net>;tag=2easdjfejw\r\n" <>
        "CSeq: 9292394834772304023312 OPTIONS\r\n" <>
        "Call-ID: scalarlg.noase0of0234hn2qofoaf0232aewf2394r\r\n" <>
        "Retry-After: 949302838503028349304023988\r\n" <>
        "Warning: 1812 overture \"In Progress\"\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n"

    assert parse(msg) == {:error, {:invalid, "CSeq"}}
    # Responses are never answered
    assert {:error, error} = Parser.parse(msg)
    assert Serializer.error_response(error) == :error
  end

  # 3.1.2.6 Unterminated Quoted String in Display Name
  test "invalid 6: quotbal" do
    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "To: \"Mr. J. User <sip:j.user@example.com>\r\n" <>
        "From: sip:caller@example.net;tag=93334\r\n" <>
        "Max-Forwards: 10\r\n" <>
        "Call-ID: quotbal.aksdj\r\n" <>
        "Contact: <sip:caller@host59.example.net>\r\n" <>
        "CSeq: 8 INVITE\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.59:5050;branch=z9hG4bKkdjuw39234\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 152\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.15\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.15\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert reply(msg, :udp) == "SIP/2.0 400 Invalid To"
  end

  # 3.1.2.7 <> Enclosing Request-URI
  test "invalid 7: ltgtruri" do
    msg =
      "INVITE <sip:user@example.com> SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=39291\r\n" <>
        "Max-Forwards: 23\r\n" <>
        "Call-ID: ltgtruri.1@192.0.2.5\r\n" <>
        "CSeq: 1 INVITE\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.5\r\n" <>
        "Contact: <sip:caller@host5.example.net>\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 159\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.5\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.5\r\n" <>
        "t=3149328700 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert reply(msg, :tcp) == "SIP/2.0 400 Invalid Request-URI"
  end

  # 3.1.2.8 Malformed SIP Request-URI (embedded LWS). Discarded, as in NkSIP.
  test "invalid 8: lwsruri" do
    msg =
      "INVITE sip:user@example.com; lr SIP/2.0\r\n" <>
        "To: sip:user@example.com;tag=3xfe-9921883-z9f\r\n" <>
        "From: sip:caller@example.net;tag=231413434\r\n" <>
        "Max-Forwards: 5\r\n" <>
        "Call-ID: lwsruri.asdfasdoeoi2323-asdfwrn23-asd834rk423\r\n" <>
        "CSeq: 2130706432 INVITE\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.1:5060;branch=z9hG4bKkdjuw2395\r\n" <>
        "Contact: <sip:caller@host1.example.net>\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 159\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.1\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.1\r\n" <>
        "t=3149328700 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert parse(msg) == {:error, :invalid_message}
  end

  # 3.1.2.9 Multiple SP Separating Request-Line Elements
  test "invalid 9: lwsstart" do
    msg =
      "INVITE  sip:user@example.com  SIP/2.0\r\n" <>
        "Max-Forwards: 8\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=8814\r\n" <>
        "Call-ID: lwsstart.dfknq234oi243099adsdfnawe3@example.com\r\n" <>
        "CSeq: 1893884 INVITE\r\n" <>
        "Via: SIP/2.0/UDP host1.example.com;branch=z9hG4bKkdjuw3923\r\n" <>
        "Contact: <sip:caller@host1.example.net>\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 150\r\n" <>
        "\r\n" <>
        @sdp_150

    assert parse(msg) == {:error, :invalid_message}
  end

  # 3.1.2.10 SP Characters at End of Request-Line
  test "invalid 10: trws" do
    msg =
      "OPTIONS sip:remote-target@example.com SIP/2.0\x20\x20\r\n" <>
        "Via: SIP/2.0/TCP host1.example.com;branch=z9hG4bK299342093\r\n" <>
        "To: <sip:remote-target@example.com>\r\n" <>
        "From: <sip:local-resource@example.com>;tag=329429089\r\n" <>
        "Call-ID: trws.oicu34958239neffasdhr2345r\r\n" <>
        "Accept: application/sdp\r\n" <>
        "CSeq: 238923 OPTIONS\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n"

    assert parse(msg) == {:error, :invalid_message}
  end

  # 3.1.2.11 Escaped Headers in SIP Request-URI. Accepted, as in NkSIP.
  test "invalid 11: escruri" do
    msg =
      "INVITE sip:user@example.com?Route=%3Csip:example.com%3E SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=341518\r\n" <>
        "Max-Forwards: 7\r\n" <>
        "Contact: <sip:caller@host39923.example.net>\r\n" <>
        "Call-ID: escruri.23940-asdfhj-aje3br-234q098w-fawerh2q-h4n5\r\n" <>
        "CSeq: 149209342 INVITE\r\n" <>
        "Via: SIP/2.0/UDP host-of-the-hour.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 150\r\n" <>
        "\r\n" <>
        @sdp_150

    assert %Message{ruri: %URI{headers: [{"route", "%3Csip:example.com%3E"}]}} = parse(msg)
  end

  # 3.1.2.12 Invalid Time Zone in Date Header Field. The Date header is not parsed.
  test "invalid 12: baddate" do
    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=2234923\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Call-ID: baddate.239423mnsadf3j23lj42--sedfnm234\r\n" <>
        "CSeq: 1392934 INVITE\r\n" <>
        "Via: SIP/2.0/UDP host.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "Date: Fri, 01 Jan 2010 16:00:00 EST\r\n" <>
        "Contact: <sip:caller@host5.example.net>\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 150\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.5\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.5\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert %Message{headers: [{"date", "Fri, 01 Jan 2010 16:00:00 EST"}]} = parse(msg)
  end

  # 3.1.2.13 Failure to Enclose name-addr URI in <>. The URI header is
  # taken as a header-level one, as in NkSIP.
  test "invalid 13: regbadct" do
    msg =
      "REGISTER sip:example.com SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:user@example.com;tag=998332\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Call-ID: regbadct.k345asrl3fdbv@10.0.0.1\r\n" <>
        "CSeq: 1 REGISTER\r\n" <>
        "Via: SIP/2.0/UDP 135.180.130.133:5060;branch=z9hG4bKkdjuw\r\n" <>
        "Contact: sip:user@example.com?Route=%3Csip:sip.example.com%3E\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert %Message{
             contacts: [%URI{headers: [], ext_headers: [{"route", "%3Csip:sip.example.com%3E"}]}]
           } =
             parse(msg)
  end

  # 3.1.2.14 Spaces within addr-spec. Accepted, as in NkSIP.
  test "invalid 14: badaspec" do
    msg =
      "OPTIONS sip:user@example.org SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP host4.example.com:5060;branch=z9hG4bKkdju43234\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "From: \"Bell, Alexander\" <sip:a.g.bell@example.com>;tag=433423\r\n" <>
        "To: \"Watson, Thomas\" < sip:t.watson@example.org >\r\n" <>
        "Call-ID: badaspec.sdf0234n2nds0a099u23h3hnnw009cdkne3\r\n" <>
        "Accept: application/sdp\r\n" <>
        "CSeq: 3923239 OPTIONS\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert %Message{
             to: %URI{
               disp: ~S("Watson, Thomas"),
               scheme: :sip,
               user: "t.watson",
               domain: "example.org",
               port: nil
             }
           } = parse(msg)
  end

  # 3.1.2.15 Non-token Characters in Display Name
  test "invalid 15: baddn" do
    msg =
      "OPTIONS sip:t.watson@example.org SIP/2.0\r\n" <>
        "Via:     SIP/2.0/UDP c.example.com:5060;branch=z9hG4bKkdjuw\r\n" <>
        "Max-Forwards:      70\r\n" <>
        "From:    Bell, Alexander <sip:a.g.bell@example.com>;tag=43\r\n" <>
        "To:      Watson, Thomas <sip:t.watson@example.org>\r\n" <>
        "Call-ID: baddn.31415@c.example.com\r\n" <>
        "Accept: application/sdp\r\n" <>
        "CSeq:    3923239 OPTIONS\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert reply(msg, :tcp) == "SIP/2.0 400 Invalid From"
  end

  # 3.1.2.16 Unknown Protocol Version. Discarded, as in NkSIP.
  test "invalid 16: badvers" do
    msg =
      "OPTIONS sip:t.watson@example.org SIP/7.0\r\n" <>
        "Via:     SIP/7.0/UDP c.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "Max-Forwards:     70\r\n" <>
        "From:    A. Bell <sip:a.g.bell@example.com>;tag=qweoiqpe\r\n" <>
        "To:      T. Watson <sip:t.watson@example.org>\r\n" <>
        "Call-ID: badvers.31417@c.example.com\r\n" <>
        "CSeq:    1 OPTIONS\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert parse(msg) == {:error, :invalid_message}
  end

  # 3.1.2.17 Start Line and CSeq Method Mismatch
  test "invalid 17: mismatch01" do
    msg =
      "OPTIONS sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:j.user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=34525\r\n" <>
        "Max-Forwards: 6\r\n" <>
        "Call-ID: mismatch01.dj0234sxdfl3\r\n" <>
        "CSeq: 8 INVITE\r\n" <>
        "Via: SIP/2.0/UDP host.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert reply(msg, :tcp) == "SIP/2.0 400 Invalid CSeq"
  end

  # 3.1.2.18 Unknown Method with CSeq Method Mismatch
  test "invalid 18: mismatch02" do
    msg =
      "NEWMETHOD sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:j.user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=34525\r\n" <>
        "Max-Forwards: 6\r\n" <>
        "Call-ID: mismatch02.dj0234sxdfl3\r\n" <>
        "CSeq: 8 INVITE\r\n" <>
        "Contact: <sip:caller@host.example.net>\r\n" <>
        "Via: SIP/2.0/UDP host.example.net;branch=z9hG4bKkdjuw\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "l: 138\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.1\r\n" <>
        "c=IN IP4 192.0.2.1\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert reply(msg, :tcp) == "SIP/2.0 400 Invalid CSeq"
  end

  # 3.1.2.19 Overlarge Response Code
  test "invalid 19: bigcode" do
    msg =
      "SIP/2.0 4294967301 better not break the receiver\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.105;branch=z9hG4bK2398ndaoe\r\n" <>
        "Call-ID: bigcode.asdof3uj203asdnf3429uasdhfas3ehjasdfas9i\r\n" <>
        "CSeq: 353494 INVITE\r\n" <>
        "From: <sip:user@example.com>;tag=39ansfi3\r\n" <>
        "To: <sip:user@example.edu>;tag=902jndnke3\r\n" <>
        "Content-Length: 0\r\n" <>
        "Contact: <sip:user@host105.example.com>\r\n" <>
        "\r\n"

    assert parse(msg) == {:error, {:invalid, "Code"}}
  end

  ## ===================================================================
  ## 3.3 and 3.4: transaction and application layer (parser level only)
  ## ===================================================================

  # 3.3.1 Missing Transaction Identifier
  test "transaction 1: badbranch" do
    msg =
      "OPTIONS sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:caller@example.org;tag=33242\r\n" <>
        "Max-Forwards: 3\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bK\r\n" <>
        "Accept: application/sdp\r\n" <>
        "Call-ID: badbranch.sadonfo23i420jv0as0derf3j3n\r\n" <>
        "CSeq: 8 OPTIONS\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert %Message{vias: [%Via{params: [{"branch", "z9hG4bK"}]}]} = parse(msg)
  end

  # 3.4.1 Missing Required Header Fields
  test "application 1: insuf" do
    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "CSeq: 193942 INVITE\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.95;branch=z9hG4bKkdj.insuf\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "l: 152\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.95\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.95\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert reply(msg, :udp) == "SIP/2.0 400 Invalid Call-ID"
  end

  # 3.4.2 to 3.4.4: unknown schemes are parsed; rejecting them with 416 is
  # done by the UAS layer
  test "application 2-4: unknown schemes" do
    common =
      "To: sip:user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=384\r\n" <>
        "Max-Forwards: 3\r\n" <>
        "Call-ID: unkscm.nasdfasser0q239nwsdfasdkl34\r\n" <>
        "CSeq: 3923423 OPTIONS\r\n" <>
        "Via: SIP/2.0/TCP host9.example.com;branch=z9hG4bKkdjuw39234\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n"

    assert %Message{ruri: %URI{scheme: "nobodyknowsthisscheme", domain: "totallyopaquecontent"}} =
             parse(
               "OPTIONS nobodyKnowsThisScheme:totallyopaquecontent SIP/2.0\r\n" <> common,
               :tcp
             )

    assert %Message{ruri: %URI{scheme: "soap.beep", domain: "192.0.2.103", port: 3002}} =
             parse("OPTIONS soap.beep://192.0.2.103:3002 SIP/2.0\r\n" <> common, :tcp)

    msg =
      "REGISTER sip:example.com SIP/2.0\r\n" <>
        "To: isbn:2983792873\r\n" <>
        "From: <http://www.example.com>;tag=3234233\r\n" <>
        "Call-ID: unksm2.daksdj@hyphenated-host.example.com\r\n" <>
        "CSeq: 234902 REGISTER\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Via: SIP/2.0/TCP 192.0.2.21:5060;branch=z9hG4bKkdjuw\r\n" <>
        "Contact: <name:John_Smith>\r\n" <>
        "l: 0\r\n" <>
        "\r\n"

    assert %Message{
             to: %URI{scheme: "isbn", domain: "2983792873"},
             from: %URI{scheme: "http", domain: "www.example.com"},
             contacts: [%URI{scheme: "name", domain: "John_Smith"}]
           } = parse(msg, :tcp)
  end

  # 3.4.5 Unknown/Malformed Option Tags; 420 is sent by the UAS layer
  test "application 5: bext01" do
    msg =
      "OPTIONS sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:j_user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=242etr\r\n" <>
        "Max-Forwards: 6\r\n" <>
        "Call-ID: bext01.0ha0isndaksdj\r\n" <>
        "Require: nothingSupportsThis, nothingSupportsThisEither\r\n" <>
        "Proxy-Require: noProxiesSupportThis, norDoAnyProxiesSupportThis\r\n" <>
        "CSeq: 8 OPTIONS\r\n" <>
        "Via: SIP/2.0/TCP fold-and-staple.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n"

    assert %Message{
             require: ["nothingSupportsThis", "nothingSupportsThisEither"],
             headers: [{"proxy-require", "noProxiesSupportThis, norDoAnyProxiesSupportThis"}]
           } = parse(msg, :tcp)
  end

  # 3.4.6 Unknown Content-Type
  test "application 6: invut" do
    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "Contact: <sip:caller@host5.example.net>\r\n" <>
        "To: sip:j.user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=8392034\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Call-ID: invut.0ha0isndaksdjadsfij34n23d\r\n" <>
        "CSeq: 235448 INVITE\r\n" <>
        "Via: SIP/2.0/UDP somehost.example.com;branch=z9hG4bKkdjuw\r\n" <>
        "Content-Type: application/unknownformat\r\n" <>
        "Content-Length: 40\r\n" <>
        "\r\n" <>
        "<audio>\r\n" <>
        " <pcmu port=\"443\"/>\r\n" <>
        "</audio>\r\n"

    assert %Message{
             content_type: {"application/unknownformat", []},
             body: "<audio>\r\n <pcmu port=\"443\"/>\r\n</audio>\r\n"
           } = parse(msg)
  end

  # 3.4.8 Multiple Values in Single Value Required Fields
  test "application 8: multi01" do
    msg =
      "INVITE sip:user@company.com SIP/2.0\r\n" <>
        "Contact: <sip:caller@host25.example.net>\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.25;branch=z9hG4bKkdjuw\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "CSeq: 5 INVITE\r\n" <>
        "Call-ID: multi01.98asdh@192.0.2.1\r\n" <>
        "CSeq: 59 INVITE\r\n" <>
        "Call-ID: multi01.98asdh@192.0.2.2\r\n" <>
        "From: sip:caller@example.com;tag=3413415\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "To: sip:other@example.net\r\n" <>
        "From: sip:caller@example.net;tag=2923420123\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "l: 152\r\n" <>
        "Contact: <sip:caller@host36.example.net>\r\n" <>
        "Max-Forwards: 5\r\n" <>
        "\r\n" <>
        "v=0\r\n" <>
        "o=mhandley 29739 7272939 IN IP4 192.0.2.25\r\n" <>
        "s=-\r\n" <>
        "c=IN IP4 192.0.2.25\r\n" <>
        "t=0 0\r\n" <>
        "m=audio 49217 RTP/AVP 0 12\r\n" <>
        "m=video 3227 RTP/AVP 31\r\n" <>
        "a=rtpmap:31 LPC\r\n"

    assert reply(msg, :udp) == "SIP/2.0 400 Invalid From"
  end

  # 3.4.9 Multiple Content-Length Values
  test "application 9: mcl01" do
    msg =
      "OPTIONS sip:user@example.com SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP host5.example.net;branch=z9hG4bK293423\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:other@example.net;tag=3923942\r\n" <>
        "Call-ID: mcl01.fhn2323orihawfdoa3o4r52o3irsdf\r\n" <>
        "CSeq: 15932 OPTIONS\r\n" <>
        "Content-Length: 13\r\n" <>
        "Max-Forwards: 60\r\n" <>
        "Content-Length: 5\r\n" <>
        "Content-Type: text/plain\r\n" <>
        "\r\n" <>
        "Theres no way to know how many octets are supposed to be here.\r\n"

    assert reply(msg, :udp) == "SIP/2.0 400 Invalid Content-Length"
  end

  # 3.4.11 Max-Forwards of Zero; rejecting it is done by the proxy layer
  test "application 11: zeromf" do
    msg =
      "OPTIONS sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:caller@example.net;tag=3ghsd41\r\n" <>
        "Call-ID: zeromf.jfasdlfnm2o2l43r5u0asdfas\r\n" <>
        "CSeq: 39234321 OPTIONS\r\n" <>
        "Via: SIP/2.0/UDP host1.example.com;branch=z9hG4bKkdjuw2349i\r\n" <>
        "Max-Forwards: 0\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n"

    assert %Message{max_forwards: 0} = parse(msg)
  end

  # 3.4.15 Unacceptable Accept Offering
  test "application 15: sdp01" do
    msg =
      "INVITE sip:user@example.com SIP/2.0\r\n" <>
        "To: sip:j_user@example.com\r\n" <>
        "Contact: <sip:caller@host15.example.net>\r\n" <>
        "From: sip:caller@example.net;tag=234\r\n" <>
        "Max-Forwards: 5\r\n" <>
        "Call-ID: sdp01.ndaksdj9342dasdd\r\n" <>
        "Accept: text/nobodyKnowsThis\r\n" <>
        "CSeq: 8 INVITE\r\n" <>
        "Via: SIP/2.0/UDP 192.0.2.15;branch=z9hG4bKkdjuw\r\n" <>
        "Content-Length: 150\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "\r\n" <>
        @sdp_150

    assert %Message{headers: [{"accept", "text/nobodyKnowsThis"}]} = parse(msg)
  end

  describe "RFC 5118 (IPv6), from t24_ipv6" do
    defp register(ruri) do
      "REGISTER #{ruri} SIP/2.0\r\n" <>
        "To: sip:user@example.com\r\n" <>
        "From: sip:user@example.com;tag=81x2\r\n" <>
        "Via: SIP/2.0/UDP [2001:db8::9:1];branch=z9hG4bKas3-111\r\n" <>
        "Call-ID: SSG9559905523997077@hlau_4100\r\n" <>
        "Max-Forwards: 70\r\n" <>
        "Contact: \"Caller\" <sip:caller@[2001:db8::1]>\r\n" <>
        "CSeq: 98176 REGISTER\r\n" <>
        "Content-Length: 0\r\n" <>
        "\r\n"
    end

    defp with_sdp(head, sdp),
      do: head <> "Content-Length: #{byte_size(sdp)}\r\n\r\n" <> sdp

    test "4.1, 4.2, 4.3 and 4.4: addresses in the Request-URI" do
      assert %Message{
               ruri: %URI{domain: "[2001:db8::10]", port: nil},
               vias: [%Via{domain: "[2001:db8::9:1]", params: [{"branch", "z9hG4bKas3-111"}]}],
               contacts: [%URI{disp: "\"Caller\"", user: "caller", domain: "[2001:db8::1]"}]
             } = parse(register("sip:[2001:db8::10]"))

      # Without brackets
      assert reply(register("sip:2001:db8::10"), :udp) == "SIP/2.0 400 Invalid Request-URI"

      # The port is inside the brackets: part of the address
      assert %Message{ruri: %URI{domain: "[2001:db8::10:5070]", port: nil}} =
               parse(register("sip:[2001:db8::10:5070]"))

      assert %Message{ruri: %URI{domain: "[2001:db8::10]", port: 5070}} =
               parse(register("sip:[2001:db8::10]:5070"))
    end

    test "4.5 and 4.6: received parameter with and without brackets" do
      msg =
        "BYE sip:[2001:db8::10] SIP/2.0\r\n" <>
          "To: sip:user@example.com;tag=bd76ya\r\n" <>
          "From: sip:user@example.com;tag=81x2\r\n" <>
          "Via: SIP/2.0/UDP [2001:db8::9:1];received=[2001:db8::9:255];branch=z9hG4bKas3-111\r\n" <>
          "Call-ID: SSG9559905523997077@hlau_4100\r\n" <>
          "Max-Forwards: 70\r\n" <>
          "CSeq: 321 BYE\r\n" <>
          "Content-Length: 0\r\n" <>
          "\r\n"

      assert %Message{vias: [%Via{domain: "[2001:db8::9:1]", params: params}]} = parse(msg)
      assert params == [{"received", "[2001:db8::9:255]"}, {"branch", "z9hG4bKas3-111"}]

      msg = String.replace(msg, "received=[2001:db8::9:255]", "received=2001:db8::9:255")
      assert %Message{vias: [%Via{params: [{"received", "2001:db8::9:255"} | _]}]} = parse(msg)

      assert :inet.parse_address(~c"2001:db8::9:255") ==
               {:ok, {0x2001, 0xDB8, 0, 0, 0, 0, 9, 0x255}}
    end

    test "4.7 and 4.9: IPv6 in SDP" do
      head =
        "INVITE sip:user@[2001:db8::10] SIP/2.0\r\n" <>
          "To: sip:user@[2001:db8::10]\r\n" <>
          "From: sip:user@example.com;tag=81x2\r\n" <>
          "Via: SIP/2.0/UDP [2001:db8::20];branch=z9hG4bKas3-111\r\n" <>
          "Call-ID: SSG9559905523997077@hlau_4100\r\n" <>
          "Contact: \"Caller\" <sip:caller@[2001:db8::20]>\r\n" <>
          "CSeq: 8612 INVITE\r\n" <>
          "Max-Forwards: 70\r\n" <>
          "Content-Type: application/sdp\r\n"

      sdp =
        "v=0\r\n" <>
          "o=assistant 971731711378798081 0 IN IP6 2001:db8::20\r\n" <>
          "s=Live video feed for today's meeting\r\n" <>
          "c=IN IP6 2001:db8::20\r\n" <>
          "t=3338481189 3370017201\r\n" <>
          "m=audio 6000 RTP/AVP 2\r\n" <>
          "a=rtpmap:2 G726-32/8000\r\n" <>
          "m=video 6024 RTP/AVP 107\r\n" <>
          "a=rtpmap:107 H263-1998/90000\r\n"

      assert %Message{to: %URI{domain: "[2001:db8::10]"}} = msg = parse(with_sdp(head, sdp))

      assert %SDP{address: {"IN", "IP6", "2001:db8::20"}, connect: {"IN", "IP6", "2001:db8::20"}} =
               SDP.from_message(msg)

      sdp =
        "v=0\r\n" <>
          "o=bob 280744730 28977631 IN IP4 host.example.com\r\n" <>
          "s=\r\n" <>
          "t=0 0\r\n" <>
          "m=audio 22334 RTP/AVP 0\r\n" <>
          "c=IN IP4 192.0.2.1\r\n" <>
          "m=video 6024 RTP/AVP 107\r\n" <>
          "c=IN IP6 2001:db8::1\r\n" <>
          "a=rtpmap:107 H263-1998/90000\r\n"

      assert %SDP{
               address: {"IN", "IP4", "host.example.com"},
               medias: [
                 %SDP.Media{connect: {"IN", "IP4", "192.0.2.1"}},
                 %SDP.Media{connect: {"IN", "IP6", "2001:db8::1"}}
               ]
             } = SDP.from_message(parse(with_sdp(head, sdp)))
    end

    test "4.8: mixed IPv4 and IPv6 Vias" do
      msg =
        "BYE sip:user@host.example.net SIP/2.0\r\n" <>
          "Via: SIP/2.0/UDP [2001:db8::9:1]:6050;branch=z9hG4bKas3-111\r\n" <>
          "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bKjhja8781hjuaij65144\r\n" <>
          "Via: SIP/2.0/TCP [2001:db8::9:255];branch=z9hG4bK451jj;received=192.0.2.200\r\n" <>
          "Call-ID: 997077@lau_4100\r\n" <>
          "Max-Forwards: 70\r\n" <>
          "CSeq: 89187 BYE\r\n" <>
          "To: sip:user@example.net;tag=9817--94\r\n" <>
          "From: sip:user@example.com;tag=81x2\r\n" <>
          "Content-Length: 0\r\n" <>
          "\r\n"

      assert %Message{
               vias: [
                 %Via{domain: "[2001:db8::9:1]", port: 6050},
                 %Via{domain: "192.0.2.1", port: nil},
                 %Via{
                   transport: :tcp,
                   domain: "[2001:db8::9:255]",
                   params: [{"branch", "z9hG4bK451jj"}, {"received", "192.0.2.200"}]
                 }
               ]
             } = parse(msg)
    end

    test "4.10: IPv4-mapped IPv6 addresses" do
      head =
        "INVITE sip:user@example.com SIP/2.0\r\n" <>
          "To: sip:user@example.com\r\n" <>
          "From: sip:user@east.example.com;tag=81x2\r\n" <>
          "Via: SIP/2.0/UDP [::ffff:192.0.2.10]:19823;branch=z9hG4bKbh19\r\n" <>
          "Via: SIP/2.0/UDP [::ffff:192.0.2.2];branch=z9hG4bKas3-111\r\n" <>
          "Call-ID: SSG9559905523997077@hlau_4100\r\n" <>
          "Contact: \"T. desk phone\" <sip:ted@[::ffff:192.0.2.2]>\r\n" <>
          "CSeq: 612 INVITE\r\n" <>
          "Max-Forwards: 70\r\n" <>
          "Content-Type: application/sdp\r\n"

      sdp =
        "v=0\r\n" <>
          "o=assistant 971731711378798081 0 IN IP6 ::ffff:192.0.2.2\r\n" <>
          "s=Call me soon, please!\r\n" <>
          "c=IN IP6 ::ffff:192.0.2.2\r\n" <>
          "t=3338481189 3370017201\r\n" <>
          "m=audio 6000 RTP/AVP 2\r\n" <>
          "a=rtpmap:2 G726-32/8000\r\n" <>
          "m=video 6024 RTP/AVP 107\r\n" <>
          "a=rtpmap:107 H263-1998/90000\r\n"

      msg = parse(with_sdp(head, sdp))

      assert %Message{
               vias: [
                 %Via{domain: "[::ffff:192.0.2.10]", port: 19_823},
                 %Via{domain: "[::ffff:192.0.2.2]", port: nil}
               ]
             } = msg

      assert %SDP{connect: {"IN", "IP6", "::ffff:192.0.2.2"}} = SDP.from_message(msg)
      assert {:error, _} = :inet.parse_strict_address(~c"2001:db8:::192.0.2.1")

      assert :inet.parse_strict_address(~c"::ffff:192.0.2.2") ==
               {:ok, {0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0202}}
    end
  end
end
