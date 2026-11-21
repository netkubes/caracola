defmodule Caracola.Tokens do
  @moduledoc """
  Parser for comma-separated token lists with parameters, as used in headers
  like `Content-Type`, `Accept`, `Supported` or `Event`. Port of NkLIB's
  `nklib_parse_tokens`.

      iex> Caracola.Tokens.parse("multipart/mixed;boundary=7a9c, text/plain")
      {:ok, [{"multipart/mixed", [{"boundary", "7a9c"}]}, {"text/plain", []}]}
  """

  import Caracola.Util

  @typedoc "A token with its parameters."
  @type token :: {String.t(), [Caracola.URI.param()]}

  @doc "Parses a token list, or a list of such binaries."
  @spec parse(binary() | [binary()]) :: {:ok, [token()]} | :error
  def parse(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case parse(value) do
        {:ok, tokens} -> {:cont, {:ok, acc ++ tokens}}
        :error -> {:halt, :error}
      end
    end)
  end

  def parse(bin) when is_binary(bin), do: tokens(strip(bin), [])

  @doc "Serializes a token or token list."
  @spec encode(token() | [token()]) :: iodata()
  def encode({_name, _params} = token), do: encode([token])

  def encode(tokens) when is_list(tokens) do
    Enum.map_intersperse(tokens, ", ", fn {name, params} -> [name, encode_params(params)] end)
  end

  defp tokens(bin, acc) do
    case name(strip(bin), "") do
      {:ok, token, ""} -> {:ok, Enum.reverse([token | acc])}
      {:ok, token, rest} -> tokens(rest, [token | acc])
      :error -> :error
    end
  end

  defp name("", ""), do: :error
  defp name("", acc), do: {:ok, {acc, []}, ""}
  defp name(<<ch, _::binary>>, "") when ch in [?;, ?,], do: :error
  defp name(<<ch, _::binary>> = rest, acc) when ch in [?;, ?,], do: opts(rest, acc, [])
  defp name(<<ch, _::binary>>, "") when is_ws(ch), do: :error
  defp name(<<ch, rest::binary>>, acc) when is_ws(ch), do: opts(strip(rest), acc, [])
  defp name(<<ch, rest::binary>>, acc), do: name(rest, <<acc::binary, ch>>)

  defp opts("", name, params), do: {:ok, {name, params}, ""}
  defp opts(";" <> rest, name, params), do: opts_key(strip(rest), "", params, name)

  defp opts("," <> rest, name, params) do
    case strip(rest) do
      "" -> :error
      rest1 -> {:ok, {name, params}, rest1}
    end
  end

  defp opts(<<ch, rest::binary>>, name, params) when is_ws(ch),
    do: opts(strip(rest), name, params)

  defp opts(_, _name, _params), do: :error

  defp opts_key("", "", _params, _name), do: :error
  defp opts_key("", acc, params, name), do: opts("", name, params ++ [{acc, nil}])
  defp opts_key(<<ch, _::binary>>, "", _params, _name) when ch in [?;, ?,, ?=], do: :error

  defp opts_key(<<ch, _::binary>> = rest, acc, params, name) when ch in [?;, ?,],
    do: opts(rest, name, params ++ [{acc, nil}])

  defp opts_key("=" <> rest, acc, params, name),
    do: opts_value(strip(rest), acc, "", params, name)

  defp opts_key(<<ch, rest::binary>>, acc, params, name) when is_ws(ch) do
    case strip(rest) do
      "" -> opts_key("", acc, params, name)
      <<ch1, _::binary>> = rest1 when ch1 in [?;, ?,, ?=] -> opts_key(rest1, acc, params, name)
      _ -> :error
    end
  end

  defp opts_key(<<ch, rest::binary>>, acc, params, name),
    do: opts_key(rest, <<acc::binary, ch>>, params, name)

  defp opts_value("", _key, "", _params, _name), do: :error
  defp opts_value("", key, acc, params, name), do: opts("", name, params ++ [{key, acc}])
  defp opts_value(<<ch, _::binary>>, _key, "", _params, _name) when ch in [?;, ?,], do: :error

  defp opts_value(~s(") <> rest, key, "", params, name) do
    case quoted(rest) do
      {:ok, value, rest} -> opts_value(rest, key, value, params, name)
      :error -> :error
    end
  end

  defp opts_value(<<ch, _::binary>> = rest, key, acc, params, name) when ch in [?;, ?,],
    do: opts(rest, name, params ++ [{key, acc}])

  defp opts_value(<<ch, rest::binary>>, key, acc, params, name) when is_ws(ch) do
    case strip(rest) do
      "" -> opts_value("", key, acc, params, name)
      <<ch1, _::binary>> = rest1 when ch1 in [?;, ?,] -> opts_value(rest1, key, acc, params, name)
      _ -> :error
    end
  end

  defp opts_value(<<ch, rest::binary>>, key, acc, params, name),
    do: opts_value(rest, key, <<acc::binary, ch>>, params, name)
end
