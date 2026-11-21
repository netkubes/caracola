defmodule Caracola.Via do
  @moduledoc """
  Via header entry. Port of NkSIP's `nksip_parse_via`.

  `transport` is an atom for known transports or the raw string otherwise.
  `port` is `nil` when absent. Parameters are `{name, value}` tuples, with
  `nil` value for flags (like `rport`).
  """

  import Caracola.Util

  @typedoc "A transport of a Via header."
  @type transport :: :udp | :tcp | :tls | :sctp | :ws | :wss | String.t()

  @typedoc "A Via header."
  @type t :: %__MODULE__{
          transport: transport(),
          domain: String.t(),
          port: :inet.port_number() | nil,
          params: [Caracola.URI.param()]
        }

  defstruct transport: :udp, domain: "", port: nil, params: []

  @doc """
  Parses a comma-separated list of Via entries, or a list of such binaries.

      iex> {:ok, [via]} = Caracola.Via.parse("SIP/2.0/UDP host:5060;branch=z9hG4bK1;rport")
      iex> {via.transport, via.domain, via.port, via.params}
      {:udp, "host", 5060, [{"branch", "z9hG4bK1"}, {"rport", nil}]}
  """
  @spec parse(binary() | [binary()]) :: {:ok, [t()]} | :error
  def parse(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case parse(value) do
        {:ok, vias} -> {:cont, {:ok, acc ++ vias}}
        :error -> {:halt, :error}
      end
    end)
  end

  def parse(bin) when is_binary(bin), do: vias(strip(bin), [])

  @doc "Serializes a Via entry."
  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = via) do
    [
      "SIP/2.0/",
      transport_to_string(via.transport),
      ?\s,
      via.domain,
      if(via.port, do: [?:, Integer.to_string(via.port)], else: []),
      encode_params(via.params)
    ]
  end

  @doc "Gets a parameter, case-insensitively."
  @spec get_param(t(), String.t()) :: {:ok, String.t() | nil} | :error
  def get_param(%__MODULE__{params: params}, name), do: find_param(params, name)

  defp transport_to_string(transport) when is_atom(transport),
    do: transport |> Atom.to_string() |> String.upcase()

  defp transport_to_string(transport), do: transport

  ## ===================================================================
  ## Parser
  ## ===================================================================

  defp vias(bin, acc) do
    case header(strip(bin)) do
      {:ok, via, ""} -> {:ok, Enum.reverse([via | acc])}
      {:ok, via, rest} -> vias(rest, [via | acc])
      :error -> :error
    end
  end

  defp header("SIP" <> rest) do
    with "/" <> rest <- strip(rest),
         "2.0" <> rest <- strip(rest),
         "/" <> rest <- strip(rest) do
      proto(strip(rest), "")
    else
      _ -> :error
    end
  end

  defp header(_), do: :error

  defp proto("", _acc), do: :error
  defp proto(<<ch, _::binary>>, "") when is_ws(ch), do: :error

  defp proto(<<ch, rest::binary>>, acc) when is_ws(ch),
    do: domain(strip(rest), "", false, %__MODULE__{transport: to_transport(acc)})

  defp proto(<<ch, rest::binary>>, acc), do: proto(rest, <<acc::binary, ch>>)

  defp domain("", acc, ip6, via) do
    if acc == "" or ip6, do: :error, else: {:ok, %{via | domain: acc}, ""}
  end

  defp domain(<<ch, _::binary>> = rest, acc, ip6, via) when ch in [?;, ??, ?,] do
    if acc == "" or ip6, do: :error, else: opts(rest, %{via | domain: acc})
  end

  defp domain("[" <> rest, "", false, via), do: domain(rest, "[", true, via)
  defp domain("[" <> _, _acc, _ip6, _via), do: :error

  defp domain("]" <> rest, acc, true, via) when acc != "",
    do: domain(rest, acc <> "]", false, via)

  defp domain("]" <> _, _acc, _ip6, _via), do: :error
  defp domain(":" <> _, "", false, _via), do: :error
  defp domain(":" <> rest, acc, false, via), do: port(strip(rest), "", %{via | domain: acc})

  defp domain(<<ch, rest::binary>>, acc, ip6, via) when is_ws(ch) do
    case strip(rest) do
      "" -> domain("", acc, ip6, via)
      <<ch1, _::binary>> = rest1 when ch1 in [?:, ?;, ?,, ?[, ?]] -> domain(rest1, acc, ip6, via)
      _ -> :error
    end
  end

  defp domain(<<ch, rest::binary>>, acc, ip6, via),
    do: domain(rest, <<acc::binary, ch>>, ip6, via)

  defp port("", acc, via) do
    case to_port(acc) do
      {:ok, port} -> {:ok, %{via | port: port}, ""}
      :error -> :error
    end
  end

  defp port(<<ch, _::binary>> = rest, acc, via) when ch in [?;, ?,] do
    case to_port(acc) do
      {:ok, port} -> opts(rest, %{via | port: port})
      :error -> :error
    end
  end

  defp port(<<ch, rest::binary>>, acc, via) when is_ws(ch) do
    case strip(rest) do
      "" -> port("", acc, via)
      <<ch1, _::binary>> = rest1 when ch1 in [?;, ?,] -> port(rest1, acc, via)
      _ -> :error
    end
  end

  defp port(<<ch, rest::binary>>, acc, via), do: port(rest, <<acc::binary, ch>>, via)

  defp opts("", via), do: {:ok, via, ""}
  defp opts(";" <> rest, via), do: opts_key(strip(rest), "", via)

  defp opts("," <> rest, via) do
    case strip(rest) do
      "" -> :error
      rest1 -> {:ok, via, rest1}
    end
  end

  defp opts(<<ch, rest::binary>>, via) when is_ws(ch), do: opts(strip(rest), via)
  defp opts(_, _via), do: :error

  defp opts_key("", "", _via), do: :error
  defp opts_key("", acc, via), do: opts("", add_param(via, {acc, nil}))
  defp opts_key(<<ch, _::binary>>, "", _via) when ch in [?;, ?,, ?=], do: :error

  defp opts_key(<<ch, _::binary>> = rest, acc, via) when ch in [?;, ?,],
    do: opts(rest, add_param(via, {acc, nil}))

  defp opts_key("=" <> rest, acc, via), do: opts_value(strip(rest), acc, "", via)

  defp opts_key(<<ch, rest::binary>>, acc, via) when is_ws(ch) do
    case strip(rest) do
      "" -> opts_key("", acc, via)
      <<ch1, _::binary>> = rest1 when ch1 in [?;, ?,, ?=] -> opts_key(rest1, acc, via)
      _ -> :error
    end
  end

  defp opts_key(<<ch, rest::binary>>, acc, via), do: opts_key(rest, <<acc::binary, ch>>, via)

  defp opts_value("", _key, "", _via), do: :error
  defp opts_value("", key, acc, via), do: opts("", add_param(via, {key, acc}))
  defp opts_value(<<ch, _::binary>>, _key, "", _via) when ch in [?;, ?,], do: :error

  # Quoted values (generic-param) keep their quotes, as in URIs
  defp opts_value(~s(") <> rest, key, "", via) do
    case quoted(rest) do
      {:ok, value, rest} -> opts_value(rest, key, value, via)
      :error -> :error
    end
  end

  defp opts_value(<<ch, _::binary>> = rest, key, acc, via) when ch in [?;, ?,],
    do: opts(rest, add_param(via, {key, acc}))

  defp opts_value(<<ch, rest::binary>>, key, acc, via) when is_ws(ch) do
    case strip(rest) do
      "" -> opts_value("", key, acc, via)
      <<ch1, _::binary>> = rest1 when ch1 in [?;, ?,] -> opts_value(rest1, key, acc, via)
      _ -> :error
    end
  end

  defp opts_value(<<ch, rest::binary>>, key, acc, via),
    do: opts_value(rest, key, <<acc::binary, ch>>, via)

  defp add_param(via, param), do: %{via | params: via.params ++ [param]}

  defp to_transport(raw) do
    case ascii_downcase(raw) do
      "udp" -> :udp
      "tcp" -> :tcp
      "tls" -> :tls
      "sctp" -> :sctp
      "ws" -> :ws
      "wss" -> :wss
      _ -> raw
    end
  end

  defp to_port(acc) do
    case to_integer(acc) do
      {:ok, port} when port <= 65_535 -> {:ok, port}
      _ -> :error
    end
  end
end

defimpl String.Chars, for: Caracola.Via do
  def to_string(via), do: via |> Caracola.Via.encode() |> IO.iodata_to_binary()
end
