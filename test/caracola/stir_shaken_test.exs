defmodule Caracola.StirShakenTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Message, StirShaken, UAC, URI}
  alias Caracola.StirShaken.Passport
  alias Caracola.Test.{ShakenUA1, ShakenUA2}

  import Caracola.Test.Helpers

  doctest StirShaken
  doctest Passport

  @x5u "https://cert.example.com/shaken.pem"
  @orig "+1 555 123-4567"
  @dest "15557654321"

  setup_all do
    {:ok, pki: pki(), other: pki()}
  end

  # A chain root -> intermediate -> signer, with P-256 keys
  defp pki do
    curve = [key: {:namedCurve, :secp256r1}]

    %{server_config: config} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: curve, intermediates: [curve], peer: curve},
        client_chain: %{root: curve, intermediates: [], peer: curve}
      })

    {roots, intermediates} = Enum.split_with(config[:cacerts], &:public_key.pkix_is_self_signed/1)
    {:ECPrivateKey, key_der} = config[:key]

    %{
      key: :public_key.pem_encode([{:ECPrivateKey, key_der, :not_encrypted}]),
      chain: pem([config[:cert] | intermediates]),
      roots: Enum.map(roots, &pem([&1]))
    }
  end

  defp pem(ders),
    do: :public_key.pem_encode(for der <- ders, do: {:Certificate, der, :not_encrypted})

  # Starts a signer and a verifier, returning the verifier URI
  defp start_uas(pki, verify, certs \\ nil) do
    start_service(ShakenUA1, stir_shaken: [key: pki.key, x5u: @x5u, attest: "A"])

    port =
      start_service(ShakenUA2,
        stir_shaken: [verify: verify],
        certs: certs || %{@x5u => pki.chain}
      )

    StirShaken.clear_cache(ShakenUA2)
    "sip:#{@dest}@127.0.0.1:#{port}"
  end

  defp invite(uri, opts) do
    identity = StirShaken.identity(ShakenUA1, @orig, [@dest], opts)
    invite(uri, opts, [{:add, "identity", identity}])
  end

  defp invite(uri, _opts, extra) do
    opts = [:auto_2xx_ack, from: "<sip:+15551234567@example.com>"] ++ extra

    case UAC.invite(ShakenUA1, uri, opts) do
      {:ok, 200, [dialog: dialog]} ->
        UAC.bye(dialog)
        200

      {:ok, code, _} ->
        code
    end
  end

  test "signed calls are verified", %{pki: pki} do
    uri = start_uas(pki, trusted: pki.roots, enforce: :all)

    assert invite(uri, origid: "id1") == 200
    assert_receive {:fetch, @x5u}

    assert_receive {:verify,
                    {:ok,
                     %{attest: "A", orig: "15551234567", dest: [@dest], origid: "id1", x5u: @x5u}}}

    # The certificate is cached
    assert invite(uri, []) == 200
    assert_receive {:verify, {:ok, _}}
    refute_receive {:fetch, _}
  end

  test "invalid identities are rejected", %{pki: pki, other: other} do
    uri = start_uas(pki, trusted: pki.roots, enforce: :invalid)

    # Without Identity it is accepted, as not enforced
    assert invite(uri, nil, []) == 200
    assert_receive {:verify, {:error, :no_identity}}

    # Old
    assert invite(uri, iat: System.os_time(:second) - 120) == 403

    # For another number
    identity = StirShaken.identity(ShakenUA1, @orig, ["15550000000"])
    assert invite(uri, nil, [{:add, "identity", identity}]) == 438

    # Not ES256
    assert invite(uri, nil, [{:add, "identity", "a.b.c;alg=RS256"}]) == 437

    # Malformed
    assert invite(uri, nil, [{:add, "identity", "nope"}]) == 438

    # Signed with another key
    [token | params] = String.split(StirShaken.identity(ShakenUA1, @orig, [@dest]), ";")
    [h, c, _] = String.split(token, ".")
    [_, _, sig] = String.split(Passport.encode(%{}, %{}, private_key(other)), ".")
    forged = Enum.join(["#{h}.#{c}.#{sig}" | params], ";")
    assert invite(uri, nil, [{:add, "identity", forged}]) == 438
  end

  test "certificates must be trusted", %{pki: pki, other: other} do
    uri = start_uas(pki, trusted: other.roots, enforce: :invalid)
    assert invite(uri, []) == 436
  end

  test "certificates must be available", %{pki: pki} do
    uri = start_uas(pki, [trusted: pki.roots, enforce: :invalid], %{})
    assert invite(uri, []) == 436
  end

  test "identity is required with enforce: :all", %{pki: pki} do
    uri = start_uas(pki, trusted: pki.roots, enforce: :all)
    assert invite(uri, nil, []) == 428
  end

  test "signing options use the asserted identity" do
    pki = pki()
    start_service(ShakenUA1, stir_shaken: [key: pki.key, x5u: @x5u])

    {:ok, from} = URI.parse_one("<sip:alice@example.com>")
    {:ok, to} = URI.parse_one("<tel:+1-555-765-4321>")
    req = %Message{class: {:req, :invite}, from: from, to: to}
    {:ok, req} = Message.update_header(req, :add, "p-asserted-identity", "<tel:+15551112222>")

    [{:add, "identity", identity}] = StirShaken.sign_opts(ShakenUA1, req)
    assert identity =~ ";info=<#{@x5u}>;alg=ES256;ppt=shaken"

    {:ok, %{header: header, claims: claims}} =
      identity |> String.split(";") |> hd() |> Passport.decode()

    assert header == %{"alg" => "ES256", "ppt" => "shaken", "typ" => "passport", "x5u" => @x5u}

    assert %{"attest" => "C", "orig" => %{"tn" => "15551112222"}, "dest" => %{"tn" => [@dest]}} =
             claims

    # Without numbers there is nothing to sign
    assert StirShaken.sign_opts(ShakenUA1, %{req | to: from, headers: []}) == []
  end

  test "passports" do
    pki = pki()
    key = private_key(pki)
    token = Passport.encode(%{"x5u" => @x5u}, %{"iat" => 1, "orig" => %{"tn" => "1"}}, key)

    assert {:ok, passport} = Passport.decode(token)
    assert passport.claims == %{"iat" => 1, "orig" => %{"tn" => "1"}}
    assert Passport.verify(passport, public_key(pki))

    refute Passport.verify(
             %{passport | signing_input: passport.signing_input <> "x"},
             public_key(pki)
           )

    refute Passport.verify(passport, public_key(pki()))
  end

  test "configuration errors" do
    assert {:error, :invalid_stir_shaken_key} =
             StirShaken.plugin_config(nil, stir_shaken: [key: "nope"])

    assert {:error, %NimbleOptions.ValidationError{}} =
             StirShaken.plugin_config(nil, stir_shaken: [attest: "D"])
  end

  defp private_key(pki) do
    [entry] = :public_key.pem_decode(pki.key)
    :public_key.pem_entry_decode(entry)
  end

  defp public_key(pki) do
    {:ECPrivateKey, _, _, params, point, _} = private_key(pki)
    {{:ECPoint, point}, params}
  end
end
