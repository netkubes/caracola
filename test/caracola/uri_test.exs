defmodule Caracola.URITest do
  use ExUnit.Case, async: true

  alias Caracola.URI

  doctest Caracola.URI

  # Ported from nklib_parse_uri EUnit tests. Differences with NkLIB:
  # absent port/user/pass/disp are nil, flags are {name, nil}, display names are
  # trimmed and quoted parameter values keep their quotes.

  defp parse(bin) do
    case URI.parse(bin) do
      {:ok, uris} -> uris
      :error -> :error
    end
  end

  test "basic forms and errors" do
    for bad <- [
          " one two sip  :  a  ",
          "abc",
          ":a",
          "<  : a>",
          "sip: ",
          "<sip:a",
          "<sip: a;",
          "sip: a:a",
          "<sip:u@a",
          ""
        ] do
      assert parse(bad) == :error, "expected error for #{inspect(bad)}"
    end

    assert [%URI{disp: nil, scheme: :sip, domain: "a", port: nil}] = parse("sip:a")
    assert [%URI{disp: nil, scheme: :sip, domain: "a"}] = parse("<sip:a>")
    assert [%URI{scheme: :sip, domain: "a"}] = parse(" \x09  sip  \r\n :  a  ")
    assert [%URI{scheme: :sip, domain: "b"}] = parse("   <  sip  :  b  >  ")
    assert [%URI{disp: ~S(Mi "disp<,:"), domain: "a"}] = parse(~S( Mi "disp<,:" <sip:a>))
    assert [%URI{domain: "a", port: 20}] = parse("sip:a : 20")
    assert [%URI{domain: "a", port: 20}] = parse("<sip:a:20>")
    assert [%URI{user: "u", domain: "a"}] = parse("sip:u@a")
    assert [%URI{user: "u", domain: "a"}] = parse("<sip:u@a >")
    assert [%URI{user: "u", domain: "a", port: 20}] = parse("<sip:u@a:20>")
    assert [%URI{user: "u", pass: "p", domain: "a", port: 20}] = parse("<sip:u:p@a:20>")
    assert [%URI{user: "u", pass: "p", domain: "a", port: nil}] = parse(" sip:u: p @ a")
    assert [%URI{domain: "a", ext_params: [{"b", nil}]}] = parse("sip: a;b")
    assert [%URI{ext_params: [{"b", nil}, {"c", "2"}]}] = parse("sip: a  ;  b ; c =  2")

    assert [%URI{user: "u", pass: "p", domain: "a", port: 20, params: [{"b", nil}, {"c", "2"}]}] =
             parse("<sip:u:p@a:20;b;c=2>")

    assert [%URI{port: 20, params: [], ext_params: [{"b", nil}, {"c", "2"}]}] =
             parse("sip:u:p@a:20;b;c=2 ")

    assert [%URI{ext_headers: [{"d", "2"}, {"f", nil}]}] = parse("sip:a?d=2&f")
    assert [%URI{headers: [{"dd", "2"}, {"ff", nil}]}] = parse("<sip:a?dd=2&ff>")

    assert [
             %URI{
               params: [{"b", nil}, {"c", "2"}],
               headers: [{"dd", "2"}, {"ff", nil}],
               ext_params: [{"g", "3"}],
               ext_headers: [{"h", nil}, {"i", nil}]
             }
           ] = parse("<sip:a;b;c=2?dd=2&ff>;g=3?h&i")
  end

  test "star" do
    assert [%URI{domain: "*"}] = parse("*")
    assert [%URI{domain: "*"}] = parse("  *  ")
    assert [%URI{domain: "*", ext_params: [{"a", nil}]}] = parse("*;a")
    assert [%URI{domain: "*"}, %URI{domain: "b"}] = parse("*, sip:b")
  end

  test "ipv6" do
    assert parse("sip : as[1::2]") == :error
    assert parse("sip :[1::2") == :error
    assert [%URI{domain: "[1:2::3]", port: 20}] = parse("sip:[1:2::3]:20")
    assert [%URI{domain: "[1:2::3]", port: 20}] = parse("<sip:  [1:2::3]  : 20  >")
    assert [%URI{user: "u", domain: "[1:2::3]"}] = parse("<sip:u@ [1:2::3]>")
    assert [%URI{user: "u", pass: "p", domain: "[1:2::3]"}] = parse("<sip:u : p @ [1:2::3]>")
  end

  test "name-addr forms" do
    assert [%URI{domain: "host"}] = parse("sip:host")
    assert [%URI{scheme: :sips, domain: "host", port: 5061}] = parse("  sips  :  host  :  5061  ")

    assert [
             %URI{
               disp: ~S("My name"),
               user: "user",
               pass: "pass",
               domain: "host",
               port: 5061,
               params: [{"transport", "tcp"}],
               headers: [{"head1", nil}],
               ext_params: [{"op1", ~S("1")}]
             }
           ] = parse(~S( "My name" <sip:user:pass@host:5061;transport=tcp?head1> ; op1="1"))

    assert [
             %URI{
               disp: "Name",
               scheme: :sips,
               domain: "host",
               port: 5061,
               ext_headers: [{"hd2", "2"}, {"hd3", "a"}]
             }
           ] = parse(" Name   < sips : host:  5061 > ?hd2=2&hd3=a")

    assert [%URI{user: "user", domain: "host", params: [{"lr", nil}, {"t", "1"}, {"d", nil}]}] =
             parse(" < sip : user@host ;lr; t=1 ;d ? a=1 >")

    assert [%URI{ext_params: [{"tag", "a48s"}]}] =
             parse(~S("A. G. Bell" <sip:agb@bell-telephone.com> ;tag=a48s))

    assert [
             %URI{
               user: "+12125551212",
               domain: "server.phone2net.com",
               ext_params: [{"tag", "887s"}]
             }
           ] = parse("sip:+12125551212@server.phone2net.com;tag=887s")

    assert [
             %URI{
               user: "xxxx",
               domain: "192.168.1.2",
               port: 5060,
               params: [{"transport", "TCP"}, {"ob", nil}],
               ext_params: [
                 {"reg-id", "1"},
                 {"+sip.instance", ~S("<urn:uuid:00000000-0000-0000-0000-000097ee887e>")}
               ]
             }
           ] =
             parse(
               "<sip:xxxx@192.168.1.2:5060;transport=TCP;ob>;reg-id=1;" <>
                 ~S(+sip.instance="<urn:uuid:00000000-0000-0000-0000-000097ee887e>")
             )

    assert [
             %URI{
               domain: "host",
               params: [{"key", ~S("my \"")}],
               headers: [{"hd", ~S("your \"")}]
             }
           ] =
             parse(~S(<sip:host;key="my \""?hd="your \"">))
  end

  test "lists" do
    assert [%URI{domain: "a"}, %URI{domain: "b"}] = parse("sip:a,sip:b")
    assert [%URI{domain: "a"}, %URI{domain: "b"}] = parse("<sip:a>  ,  sip:b  ")

    assert [%URI{domain: "a"}, %URI{domain: "b"}, %URI{domain: "c"}] =
             parse("<sip:a>,<sip:b@b>,<sip:c>")

    assert [
             %URI{user: "u1", pass: "p1", domain: "a", ext_headers: [{"a1", nil}]},
             %URI{user: "u2", pass: "p2", domain: "b", params: [{"b1", nil}]}
           ] = parse("sip:u1:p1@a?a1,<sip:u2:p2@b;b1>")

    assert {:ok, [%URI{domain: "a"}, %URI{domain: "b"}]} = URI.parse(["sip:a", "<sip:b>"])
    assert URI.parse(["sip:a", "<sip:b"]) == :error
    assert URI.parse([]) == {:ok, []}
  end

  test "uri headers are lowercased" do
    assert [%URI{headers: [{"route", "a"}], ext_headers: [{"route", "b"}]}] =
             parse("<sip:a?routE=a>?route=b")

    assert [%URI{headers: [], ext_headers: [{"route", "a"}]}] = parse("sip:a?routE=a")
  end

  test "paths" do
    assert [%URI{domain: "a", path: "/ws/1"}] = parse("sip:a/ws/1")
    assert [%URI{domain: "a", path: "/ws/1"}] = parse("sip:a/ws/1/")
    assert [%URI{domain: "a", path: "/ws"}] = parse("<sip:a/ws>")
    assert parse(" \x09  sip  \r\n :  a /ws/1  ") == :error
    assert [%URI{domain: "a", port: 20, path: "/ws"}] = parse("sip:a : 20/ws")
    assert [%URI{domain: "a", port: 20, path: "/ws"}] = parse("<sip:a:20/ws>")
    assert [%URI{user: "u", domain: "a", path: "/ws"}] = parse("sip:u@a/ws")
    assert [%URI{user: "u", domain: "a", path: "/ws "}] = parse("<sip:u@a/ws >")
    assert [%URI{user: "u", pass: "p", port: 20, path: "/ws"}] = parse("<sip:u:p@a:20/ws>")
    assert [%URI{path: "/ws", ext_params: [{"b", nil}]}] = parse("sip: a/ws;b")
    assert [%URI{path: "/ws", ext_headers: [{"d", "2"}, {"f", nil}]}] = parse("sip:a/ws?d=2&f")
    assert [%URI{path: "/ws"}, %URI{path: "/ws2"}] = parse("<sip:a/ws>  ,  sip:b/ws2")
    assert [%URI{domain: "[1:2::3]", port: 20, path: "/ws"}] = parse("sip:[1:2::3]:20/ws")
  end

  test "other schemes" do
    assert [%URI{scheme: :tel, domain: "+1234"}] = parse("tel:+1234")
    assert [%URI{scheme: "http", domain: "www.example.com"}] = parse("<http://www.example.com>")

    assert [%URI{scheme: "soap.beep", domain: "192.0.2.103", port: 3002}] =
             parse("soap.beep://192.0.2.103:3002")
  end

  test "encode" do
    for {input, output} <- [
          {"sip:a", "<sip:a>"},
          {"\"Bob\"   <sips:bob:pw@host:5061;lr;t=1?h=2>;tag=x",
           "\"Bob\" <sips:bob:pw@host:5061;lr;t=1?h=2>;tag=x"},
          {"sip:u@a;tag=1?x=y", "<sip:u@a>;tag=1?x=y"},
          {"  *  ", "*"},
          {"<sip:a/ws;transport=ws>", "<sip:a/ws;transport=ws>"}
        ] do
      [uri] = parse(input)
      assert to_string(uri) == output
      assert parse(output) == [uri]
    end

    [uri] = parse("<sip:u@a:20/ws;lr?h=1>;tag=2")
    assert IO.iodata_to_binary(URI.encode_ruri(uri)) == "sip:u@a:20;lr"
  end

  test "parameter lookup" do
    [uri] = parse("<sip:a;Transport=TCP>;TAG=1")
    assert URI.get_param(uri, "transport") == {:ok, "TCP"}
    assert URI.get_ext_param(uri, "tag") == {:ok, "1"}
    assert URI.get_param(uri, "lr") == :error
  end
end
