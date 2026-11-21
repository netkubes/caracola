defmodule Caracola.StirShaken.Passport do
  @moduledoc """
  Personal Assertion Tokens (PASSporT, RFC 8225) with the SHAKEN extension
  (RFC 8588), signed with ES256.

  A PASSporT is a JSON Web Token in compact serialization: the base64url
  encoded header, claims and signature, separated by dots. The JSON
  objects have their keys sorted and no whitespace (RFC 8225 §9).
  """

  @typedoc "The claims of a PASSporT (RFC 8225, RFC 8588), by name."
  @type claims :: %{String.t() => term()}
  @typedoc "A decoded PASSporT: header, claims, signing input and signature."
  @type t :: %{header: map(), claims: claims(), signing_input: binary(), signature: binary()}

  @doc """
  Encodes and signs a PASSporT. `header` gets `alg` (ES256) and `typ`
  (passport).
  """
  @spec encode(map(), claims(), :public_key.private_key()) :: String.t()
  def encode(header, claims, key) do
    header = Map.merge(%{"alg" => "ES256", "typ" => "passport"}, header)
    input = b64(JSON.encode!(header)) <> "." <> b64(JSON.encode!(claims))
    input <> "." <> b64(sign(input, key))
  end

  @doc """
  Decodes a PASSporT, without checking its signature.

      iex> token = "eyJhbGciOiJFUzI1NiJ9.eyJpYXQiOjF9.AAAA"
      iex> {:ok, %{header: header, claims: claims}} = Caracola.StirShaken.Passport.decode(token)
      iex> {header, claims}
      {%{"alg" => "ES256"}, %{"iat" => 1}}
      iex> Caracola.StirShaken.Passport.decode("nope")
      :error
  """
  @spec decode(String.t()) :: {:ok, t()} | :error
  def decode(token) do
    with [header, claims, signature] <- String.split(token, "."),
         {:ok, header_json} <- unb64(header),
         {:ok, claims_json} <- unb64(claims),
         {:ok, signature} <- unb64(signature),
         {:ok, %{} = header_map} <- json(header_json),
         {:ok, %{} = claims_map} <- json(claims_json) do
      {:ok,
       %{
         header: header_map,
         claims: claims_map,
         signing_input: header <> "." <> claims,
         signature: signature
       }}
    else
      _ -> :error
    end
  end

  @doc "Checks the ES256 signature of a decoded PASSporT with a public key."
  @spec verify(t(), :public_key.public_key()) :: boolean()
  def verify(%{signing_input: input, signature: <<r::256, s::256>>}, public_key) do
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :public_key.verify(input, :sha256, der, public_key)
  rescue
    _ -> false
  end

  def verify(_passport, _public_key), do: false

  # ES256 signatures are r and s, 32 bytes each (RFC 7518 §3.4), instead of
  # the DER of :public_key
  defp sign(input, key) do
    der = :public_key.sign(input, :sha256, key)
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::256, s::256>>
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp unb64(bin), do: Base.url_decode64(bin, padding: false)

  defp json(bin) do
    JSON.decode(bin)
  rescue
    _ -> :error
  end
end
