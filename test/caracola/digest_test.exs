defmodule Caracola.DigestTest do
  use ExUnit.Case, async: true

  alias Caracola.{Digest, Parser}

  doctest Caracola.Digest

  test "parse (from nksip_auth)" do
    assert Digest.parse(
             ~S(   Digest   realm   =   AV,b="1, 2\"bc\" ", qop = "auth,  auth-int,other")
           ) ==
             {:ok,
              %{
                "b" => ~S(1, 2"bc" ),
                scheme: :digest,
                realm: "AV",
                qop: [:auth, :auth_int, "other"]
              }}

    assert {:ok, %{"a" => "1", scheme: "newscheme"}} = Digest.parse("NewScheme a=1")

    assert {:ok, %{algorithm: :sha256, nc: "00000001"}} =
             Digest.parse("Digest algorithm=SHA-256, nc=00000001")

    assert {:ok, %{algorithm: :sha512_256}} = Digest.parse("Digest algorithm=sha-512-256")
    assert {:ok, %{algorithm: "MD5-sess"}} = Digest.parse("Digest algorithm=MD5-sess")

    for bad <- [
          "",
          "Digest",
          "Digest ",
          "Digest a",
          "Digest a=",
          ~S(Digest a="b),
          "Digest a=1,",
          "Digest a=1 b=2",
          "Digest =1"
        ] do
      assert Digest.parse(bad) == :error, "expected error for #{inspect(bad)}"
    end
  end

  test "responses (from nksip_auth)" do
    ha1 = Digest.ha1("user", "pass", "realm")

    assert Digest.response(:invite, "test@test.com", ha1, "gfedcba") ==
             "194370e184088fb011b140d770936009"
  end

  test "rfc 2617 example" do
    ha1 = Digest.ha1("Mufasa", "Circle Of Life", "testrealm@host.com")

    assert Digest.response("GET", "/dir/index.html", ha1, "dcd98b7102dd2f0e8b11d0f600bfb0c093",
             qop: :auth,
             cnonce: "0a4f113b",
             nc: "00000001"
           ) == "6629fae49393a05397450978507c4ef1"
  end

  test "challenge, authorization and verification" do
    challenge = Digest.challenge("Example.com", "nonce1", "op1")

    opts = [
      method: :invite,
      uri: "sip:bob@example.com",
      user: "alice",
      password: "secret",
      nc: 10
    ]

    assert {:ok, auth} = Digest.authorization(challenge, opts)
    assert {:ok, creds} = Digest.parse(auth)

    assert %{
             scheme: :digest,
             username: "alice",
             realm: "Example.com",
             nonce: "nonce1",
             uri: "sip:bob@example.com",
             algorithm: :md5,
             qop: [:auth],
             nc: "0000000a",
             opaque: "op1"
           } = creds

    assert Digest.verify(creds, :invite, "secret") == true
    assert Digest.verify(creds, :ack, "secret") == true

    assert Digest.verify(creds, :invite, {:ha1, Digest.ha1("alice", "secret", "Example.com")}) ==
             true

    assert Digest.verify(creds, :invite, "other") == false
    assert Digest.verify(creds, :bye, "secret") == false
    assert Digest.verify(Map.delete(creds, :cnonce), :invite, "secret") == :invalid
    assert Digest.verify(%{creds | qop: []}, :invite, "secret") == :invalid
    assert Digest.verify(%{creds | algorithm: :sha256}, :invite, "secret") == :invalid
    assert Digest.verify(%{creds | algorithm: "MD5-sess"}, :invite, "secret", [:md5]) == :invalid

    # ACK uses the INVITE method, and the uri can be a Caracola.URI
    {:ok, [uri]} = Caracola.URI.parse("<sip:bob@example.com;transport=tcp?h=1>")

    {:ok, auth} =
      Digest.authorization(challenge, Keyword.merge(opts, method: :ack, uri: uri, cnonce: "c"))

    assert auth =~ ~s(uri="sip:bob@example.com;transport=tcp")
    assert auth =~ ~s(cnonce="c")
    assert {:ok, creds} = Digest.parse(auth)
    assert Digest.verify(creds, :invite, "secret")
  end

  test "authorization without qop and unsupported challenges" do
    opts = [method: :register, uri: "sip:example.com", user: "u", password: "p"]
    {:ok, auth} = Digest.authorization(~S(Digest realm="r", nonce="n"), opts)
    ha1 = Digest.ha1("u", "p", "r")
    resp = Digest.response(:register, "sip:example.com", ha1, "n")

    assert auth ==
             ~s(Digest username="u", realm="r", nonce="n", uri="sip:example.com", response="#{resp}", algorithm=MD5)

    assert Digest.authorization(~S(Digest realm="r", nonce="n", qop="auth-int"), opts) == :error

    assert Digest.authorization(~S(Digest realm="r", nonce="n", algorithm=MD5-sess), opts) ==
             :error

    # An HA1 is only valid for its algorithm
    md5_ha1 = [password: {:ha1, Digest.ha1("u", "p", "r")}]

    assert Digest.authorization(
             ~S(Digest realm="r", nonce="n", algorithm=SHA-256),
             Keyword.merge(opts, md5_ha1)
           ) == :error

    assert Digest.authorization("Basic realm=r", opts) == :error
    assert Digest.authorization("bad", opts) == :error
  end

  test "rfc 7616 example (MD5 and SHA-256)" do
    # RFC 7616 §3.9.1
    for {algorithm, expected} <- [
          md5: "8ca523f5e9506fed4657c9700eebdbec",
          sha256: "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1"
        ] do
      ha1 = Digest.ha1("Mufasa", "Circle of Life", "http-auth@example.org", algorithm)

      assert Digest.response(
               "GET",
               "/dir/index.html",
               ha1,
               "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v",
               qop: :auth,
               cnonce: "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ",
               nc: "00000001",
               algorithm: algorithm
             ) == expected
    end
  end

  test "SHA-256 and SHA-512-256" do
    opts = [method: :invite, uri: "sip:bob@example.com", user: "alice", password: "secret"]

    for {algorithm, name, size} <- [{:sha256, "SHA-256", 64}, {:sha512_256, "SHA-512-256", 64}] do
      challenge = Digest.challenge("example.com", "n1", nil, algorithm)
      assert challenge =~ "algorithm=#{name}"
      assert {:ok, auth} = Digest.authorization(challenge, opts)
      assert auth =~ "algorithm=#{name}"
      assert {:ok, %{algorithm: ^algorithm, response: resp} = creds} = Digest.parse(auth)
      assert byte_size(resp) == size

      # Accepted only if the algorithm is allowed
      assert Digest.verify(creds, :invite, "secret") == :invalid
      assert Digest.verify(creds, :invite, "secret", [algorithm]) == true
      assert Digest.verify(creds, :invite, "other", [algorithm]) == false

      ha1 = Digest.ha1("alice", "secret", "example.com", algorithm)
      assert Digest.verify(creds, :invite, {:ha1, algorithm, ha1}, [algorithm]) == true
      assert Digest.verify(creds, :invite, {:ha1, ha1}, [algorithm]) == :invalid
    end

    # SHA-512/256 has its own initial values: it is not SHA-512 truncated
    refute Digest.ha1("a", "b", "c", :sha512_256) ==
             binary_part(Base.encode16(:crypto.hash(:sha512, "a:c:b"), case: :lower), 0, 64)
  end

  test "realms" do
    bin =
      "SIP/2.0 401 Unauthorized\r\n" <>
        "Via: SIP/2.0/UDP h;branch=z9hG4bK1\r\n" <>
        "From: <sip:a@b>;tag=1\r\nTo: <sip:a@b>;tag=2\r\nCall-ID: 1\r\nCSeq: 1 REGISTER\r\n" <>
        ~s(WWW-Authenticate: Digest realm="b", nonce="1"\r\n) <>
        ~s(Proxy-Authenticate: Digest realm="a", nonce="2"\r\n) <>
        ~s(WWW-Authenticate: Digest realm="b", nonce="3"\r\n) <>
        "WWW-Authenticate: invalid\r\n" <>
        "Content-Length: 0\r\n\r\n"

    {:ok, msg, ""} = Parser.parse(bin)
    assert Digest.realms(msg) == ["a", "b"]
  end
end
