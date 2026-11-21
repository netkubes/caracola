defmodule Caracola.Headers do
  @moduledoc """
  Header name handling: compact forms and canonical capitalization.

  Header names are stored lowercased (`"call-id"`) and capitalized only when
  serialized (`"Call-ID"`).
  """

  import Caracola.Util, only: [ascii_downcase: 1]

  # RFC 3261 §7.3.3 and later extensions
  @compact %{
    "a" => "accept-contact",
    "b" => "referred-by",
    "c" => "content-type",
    "d" => "request-disposition",
    "e" => "content-encoding",
    "f" => "from",
    "i" => "call-id",
    "j" => "reject-contact",
    "k" => "supported",
    "l" => "content-length",
    "m" => "contact",
    "n" => "identity-info",
    "o" => "event",
    "r" => "refer-to",
    "s" => "subject",
    "t" => "to",
    "u" => "allow-events",
    "v" => "via",
    "x" => "session-expires",
    "y" => "identity"
  }

  # Names whose canonical form is not plain capitalization of each word
  @canonical %{
    "call-id" => "Call-ID",
    "cseq" => "CSeq",
    "www-authenticate" => "WWW-Authenticate",
    "mime-version" => "MIME-Version",
    "rack" => "RAck",
    "rseq" => "RSeq",
    "sip-etag" => "SIP-ETag",
    "sip-if-match" => "SIP-If-Match"
  }

  @doc """
  Normalizes a header name as received: lowercased, compact forms expanded.

      iex> Caracola.Headers.normalize_name("v")
      "via"
      iex> Caracola.Headers.normalize_name("Content-Length")
      "content-length"
  """
  @spec normalize_name(String.t()) :: String.t()
  def normalize_name(name) do
    name = ascii_downcase(name)
    Map.get(@compact, name, name)
  end

  @doc """
  Capitalizes a lowercased header name for serialization.

      iex> Caracola.Headers.canonical_name("call-id")
      "Call-ID"
      iex> Caracola.Headers.canonical_name("user-agent")
      "User-Agent"
  """
  @spec canonical_name(String.t()) :: String.t()
  def canonical_name(name) do
    case @canonical do
      %{^name => canonical} ->
        canonical

      _ ->
        name
        |> String.split("-")
        |> Enum.map_join("-", &capitalize/1)
    end
  end

  defp capitalize(<<ch, rest::binary>>) when ch in ?a..?z, do: <<ch - 32, rest::binary>>
  defp capitalize(word), do: word
end
