defmodule Caracola.DNS do
  @moduledoc """
  Locates SIP servers following RFC 3263. Port of NkPACKET's `nkpacket_dns`,
  specialized for `sip` and `sips` URIs.

  `resolve/2` returns, in order, the `{transport, ip, port}` targets to try:

    * If the host (or `maddr`) is an IP address, or a port is given, there is
      no NAPTR or SRV lookup.
    * If a transport is given but no port, the SRV records for that
      transport are used, falling back to A/AAAA with the default port.
    * With neither, NAPTR records select the transports; without them, the
      SRV records of each supported transport are tried (UDP, TCP and TLS
      for `sip`, TLS for `sips`), and finally A/AAAA with the default
      transport (UDP for `sip`, TLS for `sips`).

  SRV records are ordered by priority and weight (RFC 2782), and the
  addresses of each host are shuffled on every call. Lookups are cached for
  `:dns_cache_ttl` milliseconds (application env, five minutes by default).

  Options:

    * `:listen` - resolve an address to listen on: no NAPTR or SRV lookups,
      and the port is `0` if not given. `all` and `all6` hosts mean every IPv4
      or IPv6 address.
    * `:cache` - set to `false` to skip the cache.
    * `:resolver` - a `Caracola.DNS.Resolver` (`Caracola.DNS.Inet` by default).
  """

  import Caracola.Util

  alias Caracola.DNS.Cache
  alias Caracola.{URI, Via}

  @typedoc "A resolved destination: transport, IP address and port."
  @type target :: {Via.transport(), :inet.ip_address(), :inet.port_number()}

  @typedoc "Why a URI cannot be resolved."
  @type error ::
          {:invalid_uri, binary()}
          | {:invalid_scheme, URI.scheme()}
          | {:invalid_transport, Via.transport()}

  @sip_transports [:udp, :tcp, :tls, :sctp, :ws, :wss]

  @naptr_services %{
    "sip+d2u" => {:sip, :udp},
    "sip+d2t" => {:sip, :tcp},
    "sip+d2s" => {:sip, :sctp},
    "sip+d2w" => {:sip, :ws},
    "sips+d2t" => {:sips, :tls},
    "sips+d2w" => {:sips, :wss}
  }

  @doc """
  Resolves a URI, a list of them, or a binary with one or more URIs.

      iex> Caracola.DNS.resolve("<sips:10.0.0.1>, sip:[::1]:5070;transport=tcp")
      {:ok, [{:tls, {10, 0, 0, 1}, 5061}, {:tcp, {0, 0, 0, 0, 0, 0, 0, 1}, 5070}]}
  """
  @spec resolve(binary() | URI.t() | [URI.t()], keyword()) ::
          {:ok, [target()]} | {:error, error()}
  def resolve(uris, opts \\ [])

  def resolve(bin, opts) when is_binary(bin) do
    case URI.parse(bin) do
      {:ok, uris} -> resolve(uris, opts)
      :error -> {:error, {:invalid_uri, bin}}
    end
  end

  def resolve(%URI{} = uri, opts), do: resolve([uri], opts)

  def resolve(uris, opts) when is_list(uris) do
    Enum.reduce_while(uris, {:ok, []}, fn uri, {:ok, acc} ->
      case resolve_uri(uri, opts) do
        {:ok, targets} -> {:cont, {:ok, acc ++ targets}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Default port for a transport (RFC 3261 and RFC 7118)."
  @spec default_port(Via.transport()) :: :inet.port_number()
  def default_port(transport) when transport in [:udp, :tcp, :sctp], do: 5060
  def default_port(:tls), do: 5061
  def default_port(:ws), do: 80
  def default_port(:wss), do: 443

  @doc "Removes all cached lookups."
  @spec clear_cache() :: :ok
  def clear_cache, do: Cache.clear()

  ## ===================================================================
  ## Resolution
  ## ===================================================================

  defp resolve_uri(%URI{scheme: scheme} = uri, opts) when scheme in [:sip, :sips] do
    host =
      case find_param(uri.params, "maddr") do
        {:ok, maddr} when is_binary(maddr) -> maddr
        _ -> uri.domain
      end

    with {:ok, transport} <- transport(scheme, uri_transport(uri)) do
      host = host(host, opts)

      if opts[:listen] do
        transport = transport || default_transport(scheme)
        {:ok, for(ip <- addresses(host, opts), do: {transport, ip, uri.port || 0})}
      else
        {:ok, targets(scheme, host, uri.port, transport, opts)}
      end
    end
  end

  defp resolve_uri(%URI{scheme: scheme}, _opts), do: {:error, {:invalid_scheme, scheme}}

  defp host("all", _opts), do: {0, 0, 0, 0}
  defp host("all6", _opts), do: {0, 0, 0, 0, 0, 0, 0, 0}

  defp host(host, _opts) do
    bare = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_strict_address(String.to_charlist(bare)) do
      {:ok, ip} -> ip
      {:error, _} -> host
    end
  end

  # No NAPTR or SRV lookups for IPs or explicit ports
  defp targets(scheme, host, port, transport, opts) when is_tuple(host) or port != nil do
    transport = transport || default_transport(scheme)
    port = port || default_port(transport)
    for ip <- addresses(host, opts), do: {transport, ip, port}
  end

  defp targets(scheme, host, nil, nil, opts) do
    with [] <- naptr_targets(scheme, host, opts),
         [] <- Enum.flat_map(srv_transports(scheme), &srv_targets(scheme, &1, host, opts)),
         do: a_targets(default_transport(scheme), host, opts)
  end

  defp targets(scheme, host, nil, transport, opts) do
    with [] <- srv_targets(scheme, transport, host, opts),
         do: a_targets(transport, host, opts)
  end

  defp a_targets(transport, host, opts) do
    port = default_port(transport)
    for ip <- ips(host, opts), do: {transport, ip, port}
  end

  defp naptr_targets(scheme, domain, opts) do
    records =
      cached({:naptr, domain}, opts, fn -> resolver(opts).naptr(domain) end)
      |> Enum.sort_by(fn {order, pref, _, _, _, _} -> {order, pref} end)

    for {_order, _pref, flags, service, "", replacement} <- records,
        ascii_downcase(flags) == "s",
        {service_scheme, transport} <- [@naptr_services[ascii_downcase(service)]],
        service_scheme == scheme or (scheme == :sip and service_scheme == :sips),
        target <- srvs(transport, replacement, opts),
        do: target
  end

  defp srv_targets(scheme, transport, host, opts) do
    case srv_domain(scheme, transport, host) do
      nil -> []
      domain -> srvs(transport, domain, opts)
    end
  end

  defp srvs(transport, domain, opts) do
    records = cached({:srv, domain}, opts, fn -> resolver(opts).srv(domain) end)

    for {target, port} <-
          sort_srv(
            for({prio, weight, port, target} <- records, do: {prio, weight, {target, port}})
          ),
        ip <- ips(target, opts),
        do: {transport, ip, port}
  end

  defp addresses(ip, _opts) when is_tuple(ip), do: [ip]
  defp addresses(host, opts), do: ips(host, opts)

  defp ips(host, opts) do
    {:ips, host}
    |> cached(opts, fn -> resolver(opts).ips(host) end)
    |> Enum.shuffle()
  end

  defp cached(key, opts, fun) do
    if Keyword.get(opts, :cache, true) do
      case Cache.get(key) do
        {:ok, value} ->
          value

        :error ->
          value = fun.()
          Cache.put(key, value)
          value
      end
    else
      fun.()
    end
  end

  defp resolver(opts), do: Keyword.get(opts, :resolver, Caracola.DNS.Inet)

  ## ===================================================================
  ## Transports
  ## ===================================================================

  defp uri_transport(uri) do
    with :error <- find_param(uri.params, "transport"),
         :error <- find_param(uri.ext_params, "transport") do
      nil
    else
      {:ok, value} when is_binary(value) -> to_transport(ascii_downcase(value))
      _ -> nil
    end
  end

  defp to_transport(value) do
    Enum.find(@sip_transports, value, &(Atom.to_string(&1) == value))
  end

  defp transport(_scheme, nil), do: {:ok, nil}
  defp transport(:sip, transport) when transport in @sip_transports, do: {:ok, transport}
  defp transport(:sips, transport) when transport in [:tls, :wss], do: {:ok, transport}
  # RFC 5630: a SIPS URI with transport=tcp (or ws) means TLS over it
  defp transport(:sips, :tcp), do: {:ok, :tls}
  defp transport(:sips, :ws), do: {:ok, :wss}
  defp transport(_scheme, transport), do: {:error, {:invalid_transport, transport}}

  defp default_transport(:sip), do: :udp
  defp default_transport(:sips), do: :tls

  defp srv_transports(:sip), do: [:udp, :tcp, :tls]
  defp srv_transports(:sips), do: [:tls]

  defp srv_domain(_scheme, :tls, host), do: "_sips._tcp." <> host

  defp srv_domain(:sip, transport, host) when transport in [:udp, :tcp, :sctp],
    do: "_sip._#{transport}." <> host

  defp srv_domain(_scheme, _transport, _host), do: nil

  ## ===================================================================
  ## RFC 2782 ordering
  ## ===================================================================

  @doc """
  Orders SRV-like records `{priority, weight, target}` following RFC 2782:
  by ascending priority and, within the same priority, randomly with a
  probability proportional to the weight.
  """
  @spec sort_srv([{non_neg_integer(), non_neg_integer(), term()}]) :: [term()]
  def sort_srv(records) do
    records
    |> Enum.group_by(&elem(&1, 0), fn {_prio, weight, target} -> {weight, target} end)
    |> Enum.sort()
    |> Enum.flat_map(fn {_prio, group} -> weighted(Enum.sort_by(group, &elem(&1, 0)), []) end)
  end

  # Entries with weight 0 go first, so they have a small chance to be selected
  defp weighted([], acc), do: Enum.reverse(acc)

  defp weighted(group, acc) do
    total = Enum.sum_by(group, &elem(&1, 0))
    pick = :rand.uniform(total + 1) - 1

    {selected, _} =
      Enum.reduce_while(group, {nil, 0}, fn {weight, _} = entry, {nil, sum} ->
        sum = sum + weight
        if sum >= pick, do: {:halt, {entry, sum}}, else: {:cont, {nil, sum}}
      end)

    {_weight, target} = selected
    weighted(List.delete(group, selected), [target | acc])
  end
end
