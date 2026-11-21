defmodule Caracola.SerializerTest do
  use ExUnit.Case, async: true

  alias Caracola.{Message, Parser, Serializer}

  doctest Caracola.Serializer

  @invite "INVITE sip:bob@biloxi.example.com;transport=tcp SIP/2.0\r\n" <>
            "v: SIP/2.0/TCP client.atlanta.example.com:5060;branch=z9hG4bK74b43\r\n" <>
            "Max-Forwards: 70\r\n" <>
            "Route: <sip:ss1.atlanta.example.com;lr>\r\n" <>
            "From: Alice <sip:alice@atlanta.example.com>;tag=9fxced76sl\r\n" <>
            "To: Bob <sip:bob@biloxi.example.com>\r\n" <>
            "Call-ID: 3848276298220188511@atlanta.example.com\r\n" <>
            "CSeq: 1 INVITE\r\n" <>
            "Contact: <sip:alice@client.atlanta.example.com;transport=tcp>\r\n" <>
            "Supported: path,  100rel\r\n" <>
            "User-Agent: Test\r\n" <>
            "Content-Type: application/sdp\r\n" <>
            "Content-Length: 4\r\n" <>
            "\r\n" <>
            "v=0\n"

  test "encodes a request with headers in canonical order" do
    {:ok, msg, ""} = Parser.parse(@invite, :tcp)

    assert Serializer.encode(msg) ==
             "INVITE sip:bob@biloxi.example.com;transport=tcp SIP/2.0\r\n" <>
               "Via: SIP/2.0/TCP client.atlanta.example.com:5060;branch=z9hG4bK74b43\r\n" <>
               "From: Alice <sip:alice@atlanta.example.com>;tag=9fxced76sl\r\n" <>
               "To: Bob <sip:bob@biloxi.example.com>\r\n" <>
               "Call-ID: 3848276298220188511@atlanta.example.com\r\n" <>
               "CSeq: 1 INVITE\r\n" <>
               "Max-Forwards: 70\r\n" <>
               "Content-Length: 4\r\n" <>
               "Route: <sip:ss1.atlanta.example.com;lr>\r\n" <>
               "Contact: <sip:alice@client.atlanta.example.com;transport=tcp>\r\n" <>
               "Content-Type: application/sdp\r\n" <>
               "Supported: path, 100rel\r\n" <>
               "User-Agent: Test\r\n" <>
               "\r\n" <>
               "v=0\n"
  end

  test "encodes responses, using the standard reason phrase if empty" do
    {:ok, req, ""} = Parser.parse(@invite, :tcp)
    resp = %Message{req | class: {:resp, 180, ""}, ruri: nil, body: "", content_type: nil}

    assert "SIP/2.0 180 Ringing\r\nVia: " <> _ = Serializer.encode(resp)
    assert "SIP/2.0 180 Sonando\r\n" <> _ = to_string(%{resp | class: {:resp, 180, "Sonando"}})
  end

  test "content-length is computed from the body" do
    {:ok, msg, ""} = Parser.parse(@invite, :tcp)
    bin = Serializer.encode(%{msg | body: "longer body"})
    assert bin =~ "\r\nContent-Length: 11\r\n"
    assert {:ok, %Message{body: "longer body"}, ""} = Parser.parse(bin, :tcp)
  end

  test "parse and encode round trip" do
    messages = [
      @invite,
      "SIP/2.0 200 OK\r\n" <>
        "Via: SIP/2.0/UDP [2001:db8::9:1]:5070;branch=z9hG4bKas;received=[2001:db8::9:255]\r\n" <>
        ~S(From: "Bob \"B\"" <sips:bob@example.com>;tag=1) <>
        "\r\n" <>
        "To: <sip:alice@example.com;user=phone>;tag=2\r\n" <>
        "Call-ID: abc\r\n" <>
        "CSeq: 2 SUBSCRIBE\r\n" <>
        "Contact: *\r\n" <>
        "Expires: 3600\r\n" <>
        "Event: presence;id=1\r\n" <>
        "Require: 100rel\r\n" <>
        "X-Custom: a, b\r\n" <>
        "X-Custom: c\r\n" <>
        "l: 0\r\n\r\n",
      "MESSAGE sip:u@[::1]:5060 SIP/2.0\r\n" <>
        "Via: SIP/2.0/WSS h.invalid;branch=z9hG4bK1;rport\r\n" <>
        "From: sip:a@b?subject=x;tag=1\r\n" <>
        "To: tel:+1234\r\n" <>
        "Call-ID: x@y\r\n" <>
        "CSeq: 10 MESSAGE\r\n" <>
        "Content-Type: text/plain;charset=UTF-8\r\n" <>
        "Content-Length: 5\r\n\r\nhello"
    ]

    for bin <- messages do
      assert {:ok, msg, ""} = Parser.parse(bin, :tcp)
      encoded = Serializer.encode(msg)
      assert {:ok, ^msg, ""} = Parser.parse(encoded, :tcp)
      # Encoding is stable
      assert Serializer.encode(msg) == encoded
    end
  end

  test "error response for invalid requests" do
    bin =
      "INVITE sip:a@b SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP host;branch=z9hG4bK1\r\n" <>
        "Via: SIP/2.0/UDP host2;branch=z9hG4bK2\r\n" <>
        "From: <sip:c@d>;tag=1\r\n" <>
        "To: \"unbalanced <sip:a@b>\r\n" <>
        "Call-ID: 123\r\n" <>
        "CSeq: 1 INVITE\r\n" <>
        "\r\n"

    assert {:error, %Caracola.ParseError{reason: {:invalid, "To"}} = error} = Parser.parse(bin)

    assert Serializer.error_response(error) ==
             {:ok,
              "SIP/2.0 400 Invalid To\r\n" <>
                "Via: SIP/2.0/UDP host;branch=z9hG4bK1\r\n" <>
                "Via: SIP/2.0/UDP host2;branch=z9hG4bK2\r\n" <>
                "From: <sip:c@d>;tag=1\r\n" <>
                "To: \"unbalanced <sip:a@b>\r\n" <>
                "Call-ID: 123\r\n" <>
                "CSeq: 1 INVITE\r\n" <>
                "Content-Length: 0\r\n\r\n"}

    assert_raise Caracola.ParseError, "invalid To header", fn -> Parser.parse!(bin) end
  end

  test "framing" do
    assert Parser.parse("", :tcp) == :partial
    assert Parser.parse("INVITE sip:a@b SIP/2.0\r\nVia: x", :tcp) == :partial
    assert {:error, %Caracola.ParseError{reason: :invalid_message}} = Parser.parse("garbage")

    # Content-Length is mandatory on stream transports
    no_cl =
      "OPTIONS sip:a@b SIP/2.0\r\nVia: SIP/2.0/TCP h\r\nFrom: <sip:a@b>\r\nTo: <sip:a@b>\r\nCall-ID: 1\r\nCSeq: 1 OPTIONS\r\n\r\n"

    assert {:error, %{reason: {:invalid, "Content-Length"}}} = Parser.parse(no_cl, :tcp)
    assert {:ok, %Message{body: ""}, ""} = Parser.parse(no_cl, :udp)

    # Leading CRLFs (keepalives) are skipped, trailing data is returned
    {:ok, msg, ""} = Parser.parse(@invite, :tcp)

    assert {:ok, ^msg, "\r\n\r\nINVITE"} =
             Parser.parse("\r\n\r\n" <> @invite <> "\r\n\r\nINVITE", :tcp)

    # SUBSCRIBE and NOTIFY require Event
    sub =
      "SUBSCRIBE sip:a@b SIP/2.0\r\nVia: SIP/2.0/UDP h\r\nFrom: <sip:a@b>\r\nTo: <sip:a@b>\r\nCall-ID: 1\r\nCSeq: 1 SUBSCRIBE\r\n\r\n"

    assert {:error, %{reason: {:invalid, "Event"}}} = Parser.parse(sub)
  end
end
