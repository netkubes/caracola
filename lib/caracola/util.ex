defmodule Caracola.Util do
  @moduledoc false
  # Low level helpers shared by the parsers and serializers.

  defguard is_ws(ch) when ch in [?\s, ?\t, ?\r, ?\n]

  @doc "Removes leading whitespace (SP, HT, CR, LF)."
  @spec strip(binary()) :: binary()
  def strip(<<ch, rest::binary>>) when is_ws(ch), do: strip(rest)
  def strip(bin), do: bin

  @doc "Removes leading and trailing whitespace (SP, HT, CR, LF)."
  @spec trim(binary()) :: binary()
  def trim(bin), do: bin |> strip() |> strip_trailing()

  @doc "Removes trailing whitespace (SP, HT, CR, LF)."
  @spec strip_trailing(binary()) :: binary()
  def strip_trailing(""), do: ""

  def strip_trailing(bin) do
    size = byte_size(bin) - 1

    case bin do
      <<rest::binary-size(^size), ch>> when is_ws(ch) -> strip_trailing(rest)
      _ -> bin
    end
  end

  @doc "Parses a non-negative decimal integer, allowing surrounding whitespace."
  @spec to_integer(binary()) :: {:ok, non_neg_integer()} | :error
  def to_integer(bin) do
    case trim(bin) do
      "" -> :error
      digits -> if all_digits?(digits), do: {:ok, String.to_integer(digits)}, else: :error
    end
  end

  defp all_digits?(<<ch, rest::binary>>) when ch in ?0..?9, do: all_digits?(rest)
  defp all_digits?(<<>>), do: true
  defp all_digits?(_), do: false

  @doc "Lowercases ASCII letters only, leaving other bytes untouched."
  @spec ascii_downcase(binary()) :: binary()
  def ascii_downcase(bin) do
    for <<ch <- bin>>, into: "", do: <<if(ch in ?A..?Z, do: ch + 32, else: ch)>>
  end

  @doc """
  Reads a quoted string, starting after the opening quote. The value is
  returned with its quotes and escapes, followed by the rest of the input.
  """
  @spec quoted(binary()) :: {:ok, binary(), binary()} | :error
  def quoted(bin), do: quoted(bin, ~s("))

  defp quoted(<<?\\, ch, rest::binary>>, acc), do: quoted(rest, <<acc::binary, ?\\, ch>>)
  defp quoted(~s(") <> rest, acc), do: {:ok, acc <> ~s("), rest}
  defp quoted(<<ch, rest::binary>>, acc), do: quoted(rest, <<acc::binary, ch>>)
  defp quoted("", _acc), do: :error

  @doc "Serializes a parameter list as `;key=value;flag`."
  @spec encode_params([{binary(), binary() | nil}]) :: iodata()
  def encode_params(params) do
    for {key, value} <- params do
      if value == nil, do: [?;, key], else: [?;, key, ?=, value]
    end
  end

  @doc "Finds a parameter value by name, case-insensitively."
  @spec find_param([{binary(), binary() | nil}], binary()) :: {:ok, binary() | nil} | :error
  def find_param(params, name) do
    name = ascii_downcase(name)

    Enum.find_value(params, :error, fn {key, value} ->
      if ascii_downcase(key) == name, do: {:ok, value}
    end)
  end

  @doc """
  Gets the value of `key` in an option list that may also contain flags
  (bare atoms), where `Keyword` functions cannot be used.
  """
  @spec opt(list(), term(), term()) :: term()
  def opt(opts, key, default \\ nil)
  def opt([{key, value} | _], key, _default), do: value
  def opt([_ | rest], key, default), do: opt(rest, key, default)
  def opt([], _key, default), do: default

  @doc "Checks if an option list (with flags) has a `{key, value}` option."
  @spec opt?(list(), term()) :: boolean()
  def opt?(opts, key), do: Enum.any?(opts, &match?({^key, _}, &1))

  @doc "Generates a random identifier (tags, branches, Call-IDs...)."
  @spec uid() :: String.t()
  def uid, do: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)

  @doc "A short hash of a term, as used in deterministic tags."
  @spec hash(term()) :: String.t()
  def hash(term) do
    <<hash::binary-size(10), _::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(term))
    Base.encode32(hash, case: :lower, padding: false)
  end

  @doc "Random identifier of this node, generated at startup."
  @spec global_id() :: String.t()
  def global_id do
    case :persistent_term.get({__MODULE__, :global_id}, nil) do
      nil ->
        id = uid()
        :persistent_term.put({__MODULE__, :global_id}, id)
        id

      id ->
        id
    end
  end

  @doc """
  Returns a new CSeq number. The counter starts with a value based on the
  current time, so that it keeps increasing across restarts.
  """
  @spec next_cseq() :: pos_integer()
  def next_cseq do
    counter =
      case :persistent_term.get({__MODULE__, :cseq}, nil) do
        nil ->
          ref = :atomics.new(1, signed: false)
          # Seconds since 2012, as NkSIP does, fit in 31 bits until 2080
          :atomics.put(ref, 1, System.os_time(:second) - 1_325_376_000)
          :persistent_term.put({__MODULE__, :cseq}, ref)
          ref

        ref ->
          ref
      end

    :atomics.add_get(counter, 1, 1)
  end

  @doc """
  Host to use in Via and Contact headers for a listener on `ip`: the
  configured `local_host` (or `local_host6`), or else the listening address
  or, for listeners on every address, the main address of the machine.
  """
  @spec local_host(:inet.ip_address(), keyword()) :: String.t()
  def local_host(ip, config) when tuple_size(ip) == 4 do
    case config[:local_host] do
      host when is_binary(host) -> host
      _ when ip == {0, 0, 0, 0} -> ip_to_host(main_ip(:inet))
      _ -> ip_to_host(ip)
    end
  end

  def local_host(ip, config) when tuple_size(ip) == 8 do
    case config[:local_host6] do
      host when is_binary(host) -> host
      _ when ip == {0, 0, 0, 0, 0, 0, 0, 0} -> ip_to_host(main_ip(:inet6))
      _ -> ip_to_host(ip)
    end
  end

  @doc """
  Removes the brackets of an IPv6 host.

      iex> Caracola.Util.unbracket("[::1]")
      "::1"
      iex> Caracola.Util.unbracket("host")
      "host"
  """
  @spec unbracket(String.t()) :: String.t()
  def unbracket("[" <> rest), do: String.trim_trailing(rest, "]")
  def unbracket(host), do: host

  @doc "Formats an IP as a host (IPv6 addresses go between brackets)."
  @spec ip_to_host(:inet.ip_address()) :: String.t()
  def ip_to_host(ip) when tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]"
  def ip_to_host(ip), do: to_string(:inet.ntoa(ip))

  @typedoc "An IP network: an address and a prefix length."
  @type network :: {:inet.ip_address(), non_neg_integer()}

  @doc """
  Parses a list of networks, as `10.0.0.0/8`, `192.0.2.1` or `2001:db8::/32`.

      iex> Caracola.Util.parse_networks(["10.0.0.0/8", "192.0.2.1"])
      {:ok, [{{10, 0, 0, 0}, 8}, {{192, 0, 2, 1}, 32}]}
      iex> Caracola.Util.parse_networks(["10.0.0.0/33"])
      {:error, {:invalid_network, "10.0.0.0/33"}}
  """
  @spec parse_networks([String.t()]) :: {:ok, [network()]} | {:error, term()}
  def parse_networks(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case parse_network(value) do
        {:ok, network} -> {:cont, {:ok, acc ++ [network]}}
        :error -> {:halt, {:error, {:invalid_network, value}}}
      end
    end)
  end

  defp parse_network(value) do
    {addr, bits} =
      case String.split(value, "/") do
        [addr, bits] -> {addr, Integer.parse(bits)}
        [addr] -> {addr, nil}
      end

    case :inet.parse_address(String.to_charlist(unbracket(addr))) do
      {:ok, ip} -> prefix(ip, bits, if(tuple_size(ip) == 4, do: 32, else: 128))
      {:error, _} -> :error
    end
  end

  defp prefix(ip, nil, size), do: {:ok, {ip, size}}
  defp prefix(ip, {bits, ""}, size) when bits >= 0 and bits <= size, do: {:ok, {ip, bits}}
  defp prefix(_ip, _bits, _size), do: :error

  @doc """
  Returns `true` if an address belongs to any of the networks.

      iex> {:ok, nets} = Caracola.Util.parse_networks(["10.0.0.0/8"])
      iex> Caracola.Util.in_networks?({10, 1, 2, 3}, nets)
      true
      iex> Caracola.Util.in_networks?({11, 1, 2, 3}, nets)
      false
  """
  @spec in_networks?(:inet.ip_address(), [network()]) :: boolean()
  def in_networks?(ip, networks), do: Enum.any?(networks, &in_network?(ip, &1))

  defp in_network?(ip, {net, bits}) when tuple_size(ip) == tuple_size(net) do
    size = if tuple_size(ip) == 4, do: 32, else: 128
    <<a::bitstring-size(^bits), _::bitstring>> = ip_bits(ip, size)
    <<b::bitstring-size(^bits), _::bitstring>> = ip_bits(net, size)
    a == b
  end

  defp in_network?(_ip, _network), do: false

  defp ip_bits({a, b, c, d}, 32), do: <<a, b, c, d>>
  defp ip_bits(ip, 128), do: for(part <- Tuple.to_list(ip), into: <<>>, do: <<part::16>>)

  # First address of an interface that is up and not a loopback
  defp main_ip(family) do
    size = if family == :inet, do: 4, else: 8

    with {:ok, ifaces} <- :inet.getifaddrs(),
         ip when ip != nil <- Enum.find_value(ifaces, &iface_ip(&1, size)) do
      ip
    else
      _ -> if family == :inet, do: {127, 0, 0, 1}, else: {0, 0, 0, 0, 0, 0, 0, 1}
    end
  end

  defp iface_ip({_name, opts}, size) do
    flags = Keyword.get(opts, :flags, [])

    if :up in flags and :loopback not in flags,
      do:
        Enum.find(
          Keyword.get_values(opts, :addr),
          &(tuple_size(&1) == size and not link_local?(&1))
        )
  end

  defp link_local?({a, _, _, _, _, _, _, _}), do: Bitwise.band(a, 0xFFC0) == 0xFE80
  defp link_local?(_), do: false
end
