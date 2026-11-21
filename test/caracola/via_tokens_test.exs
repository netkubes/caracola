defmodule Caracola.ViaTokensTest do
  use ExUnit.Case, async: true

  alias Caracola.{Tokens, Via}

  doctest Caracola.Via
  doctest Caracola.Tokens
  doctest Caracola.Headers
  doctest Caracola.Message

  # Ported from nksip_parse_via EUnit tests
  test "vias" do
    assert Via.parse("SIP/3.0/udp host") == :error
    assert Via.parse("SIP/2.0/udp ") == :error
    assert Via.parse("SIP/2.0/udp a, ") == :error

    assert {:ok,
            [
              %Via{
                transport: :udp,
                port: nil,
                params: [{"rport", nil}, {"received", "1.2.3.4"}, {"c", nil}]
              }
            ]} =
             Via.parse("SIP/2.0/udp host;rport;received=1.2.3.4 ; c")

    assert {:ok,
            [
              %Via{transport: "kkk", domain: "host", port: 1500, params: []},
              %Via{transport: :udp, domain: "[1:2::3]", port: 25, params: [{"d", nil}]}
            ]} = Via.parse("  SIP  / 2.0  / kkk     host : 1500  ,  SIP/2.0/UdP [1:2::3]:25;d")

    assert {:ok, [%Via{transport: :tcp, domain: "host", port: 12}]} =
             Via.parse("  SIP / 2.0/TCP host:12")

    assert {:ok,
            [
              %Via{transport: :tls, domain: "host", port: nil},
              %Via{
                domain: "host2",
                port: 5061,
                params: [{"maddr", nil}, {"received", "1.2.3.4"}, {"a", nil}]
              }
            ]} =
             Via.parse(
               "SIP/2.0/TLS  host  ,  SIP / 2.0 / UDP host2 : 5061  ; maddr; received = 1.2.3.4 ; a"
             )
  end

  test "via encode" do
    {:ok, [via]} = Via.parse("SIP/2.0/tcp host:5060;branch=z9hG4bK1;rport")
    assert to_string(via) == "SIP/2.0/TCP host:5060;branch=z9hG4bK1;rport"
    assert Via.get_param(via, "BRANCH") == {:ok, "z9hG4bK1"}
  end

  test "token quoted parameters" do
    assert Tokens.parse(~S(multipart/mixed;boundary="a b, c";x=1, text/plain)) ==
             {:ok,
              [{"multipart/mixed", [{"boundary", ~S("a b, c")}, {"x", "1"}]}, {"text/plain", []}]}

    assert Tokens.parse(~S(a;b="c)) == :error
  end

  test "via quoted parameters" do
    assert {:ok,
            [%Via{params: [{"branch", "z9hG4bK1"}, {"x", ~S("a; \"b\", c")}]}, %Via{domain: "h2"}]} =
             Via.parse(~S(SIP/2.0/UDP h;branch=z9hG4bK1;x="a; \"b\", c" , SIP/2.0/UDP h2))

    assert Via.parse(~S(SIP/2.0/UDP h;x="a)) == :error
  end

  # Ported from nklib_parse_tokens EUnit tests
  test "tokens" do
    assert Tokens.parse("   aaa  , ") == :error
    assert Tokens.parse("   aaa; ") == :error
    assert Tokens.parse("   aaa;b= , c") == :error
    assert Tokens.parse("aaa") == {:ok, [{"aaa", []}]}
    assert Tokens.parse("   aaa   ") == {:ok, [{"aaa", []}]}

    assert Tokens.parse(~S(aaa ,  bbb,ccc,eee;c  ;  d  ; e = 1  ; g=2, fff;h="3")) ==
             {:ok,
              [
                {"aaa", []},
                {"bbb", []},
                {"ccc", []},
                {"eee", [{"c", nil}, {"d", nil}, {"e", "1"}, {"g", "2"}]},
                {"fff", [{"h", ~S("3")}]}
              ]}

    assert IO.iodata_to_binary(Tokens.encode([{"a", [{"b", nil}, {"c", "1"}]}, {"d", []}])) ==
             "a;b;c=1, d"
  end
end
