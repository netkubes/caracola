defmodule Caracola.DNS.Resolver do
  @moduledoc """
  Behaviour for the DNS lookups used by `Caracola.DNS`. The default
  implementation, `Caracola.DNS.Inet`, uses `:inet_res` and `:inet`; tests
  can provide their own.
  """

  @typedoc "A NAPTR record: order, preference, flags, service, regexp and replacement."
  @type naptr ::
          {order :: non_neg_integer(), preference :: non_neg_integer(), flags :: String.t(),
           service :: String.t(), regexp :: String.t(), replacement :: String.t()}

  @typedoc "An SRV record: priority, weight, port and target host."
  @type srv ::
          {priority :: non_neg_integer(), weight :: non_neg_integer(),
           port :: :inet.port_number(), target :: String.t()}

  @doc "The NAPTR records of a domain, to find the transports of a URI (RFC 3263)."
  @callback naptr(domain :: String.t()) :: [naptr()]
  @doc "The SRV records of a name such as `_sip._udp.example.com`."
  @callback srv(domain :: String.t()) :: [srv()]
  @doc "The IP addresses (A and AAAA) of a host name."
  @callback ips(host :: String.t()) :: [:inet.ip_address()]
end

defmodule Caracola.DNS.Inet do
  @moduledoc """
  `Caracola.DNS.Resolver` using the system resolver.
  """

  @behaviour Caracola.DNS.Resolver

  @impl true
  def naptr(domain) do
    for {order, pref, flags, service, regexp, replacement} <- lookup(domain, :naptr) do
      {order, pref, to_string(flags), to_string(service), to_string(regexp),
       to_string(replacement)}
    end
  end

  @impl true
  def srv(domain) do
    for {prio, weight, port, target} <- lookup(domain, :srv),
        do: {prio, weight, port, to_string(target)}
  end

  @impl true
  def ips(host) do
    host = String.to_charlist(host)

    case :inet.getaddrs(host, :inet) do
      {:ok, ips} ->
        Enum.uniq(ips)

      {:error, _} ->
        case :inet.getaddrs(host, :inet6) do
          {:ok, ips} -> Enum.uniq(ips)
          {:error, _} -> []
        end
    end
  end

  defp lookup(domain, type), do: :inet_res.lookup(String.to_charlist(domain), :in, type)
end
