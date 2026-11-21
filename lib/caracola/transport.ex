defmodule Caracola.Transport do
  @moduledoc """
  SIP transport layer: listeners, connections and sending. Replaces the
  parts of NkPACKET used by NkSIP.

    * UDP listeners also listen on TCP on the same port, as RFC 3261 §18
      requires. Incoming TCP, TLS, WS and WSS connections are handled by
      ThousandIsland.
    * SIP over WebSocket (RFC 7118) uses the `sip` subprotocol, with each
      message in a WebSocket message.
    * Connections are kept in a table keyed by service, transport and peer
      address, and reused to send to the same peer. They are closed after
      `:idle_timeout` milliseconds without traffic.
    * UDP messages are sent from the listener socket, so that they come
      from the listening port.
    * Received messages are given to the listener's handler, see
      `Caracola.Transport.Handler`.

  `service` is any term identifying the owner of listeners and connections
  (the Malla service id).
  """

  alias Caracola.{DNS, Message, Serializer, URI, Util}
  alias Caracola.Transport.{Connection, Listener, Port, WS}

  @listeners Caracola.Transport.Listeners
  @connections Caracola.Transport.Connections
  @listener_sup Caracola.Transport.ListenerSup
  @connection_sup Caracola.Transport.ConnectionSup

  @default_idle_timeout :timer.minutes(3)
  @max_udp 65_507

  @transports [:udp, :tcp, :tls, :ws, :wss]
  @connection_transports [:tcp, :tls, :ws, :wss]

  @typedoc "Where to send: a URI (as a binary or `Caracola.URI`) or an already resolved target."
  @type target :: binary() | URI.t() | DNS.target()

  @doc false
  def children do
    [
      {Registry, keys: :duplicate, name: @listeners},
      {Registry, keys: :unique, name: @connections, partitions: System.schedulers_online()},
      {Registry, keys: :unique, name: Caracola.Transport.Names},
      {DynamicSupervisor, name: @listener_sup, strategy: :one_for_one},
      {PartitionSupervisor, child_spec: DynamicSupervisor, name: @connection_sup}
    ]
  end

  ## ===================================================================
  ## Listeners
  ## ===================================================================

  @doc """
  Starts a listener for `service`.

  Options:

    * `:ip` - address to listen on (tuple or string), `{0, 0, 0, 0}` by default.
    * `:port` - the default port of the transport if not given, `0` for a
      random one. For UDP, the TCP listener uses the same port.
    * `:handler` - `{module, arg}` receiving the messages.
    * `:idle_timeout` - for incoming connections, in milliseconds (three
      minutes by default).
    * `:tls` - `:ssl` options for TLS and WSS listeners (`certfile`,
      `keyfile`...).
    * `:path` - for WS and WSS, the only HTTP path accepted (any by default).
  """
  @spec start_listener(term(), Port.transport(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_listener(service, transport, opts \\ []) when transport in @transports do
    with {:ok, opts} <- listener_opts(transport, opts), do: start_child(service, transport, opts)
  end

  @doc """
  Child spec of a listener, to start it under another supervisor. Options
  as in `start_listener/3`.
  """
  @spec listener_spec(term(), Port.transport(), keyword()) :: Supervisor.child_spec()
  def listener_spec(service, transport, opts) when transport in @transports do
    {:ok, opts} = listener_opts(transport, opts)

    # Several listeners could have port 0
    Supervisor.child_spec({Listener, {service, transport, opts}},
      id: {Listener, transport, opts[:ip], opts[:port], make_ref()},
      restart: :permanent
    )
  end

  defp listener_opts(transport, opts) do
    with {:ok, ip} <- to_ip(Keyword.get(opts, :ip, {0, 0, 0, 0})) do
      {:ok,
       Keyword.merge(opts,
         ip: ip,
         port: Keyword.get(opts, :port, DNS.default_port(transport)),
         idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout)
       )}
    end
  end

  defp start_child(service, transport, opts) do
    case DynamicSupervisor.start_child(@listener_sup, {Listener, {service, transport, opts}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, {:failed_to_start_child, _, reason}}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops a listener started with `start_listener/3`."
  @spec stop_listener(pid()) :: :ok | {:error, :not_found}
  def stop_listener(pid), do: DynamicSupervisor.terminate_child(@listener_sup, pid)

  @doc "Returns the listeners of a service, optionally only for a transport."
  @spec listeners(term(), Port.transport() | nil) :: [Port.t()]
  def listeners(service, transport \\ nil) do
    @listeners
    |> Registry.select([
      {{{:"$1", :"$2"}, :_, :"$3"}, [{:==, :"$1", {:const, service}}], [{{:"$2", :"$3"}}]}
    ])
    |> Enum.flat_map(fn {t, port} -> if transport in [nil, t], do: [port], else: [] end)
    |> Enum.sort_by(&{&1.transport, &1.local_port})
  end

  @doc """
  Returns `true` if `uri` points to one of the listeners of the service:
  same port (the default one of the transport if missing) and an address
  of the listener, `localhost`, or the `:local_host` and `:local_host6` of
  `config`. Host names are not resolved.
  """
  @spec local?(term(), URI.t(), keyword()) :: boolean()
  def local?(service, %URI{domain: domain} = uri, config \\ []) do
    port = uri.port || DNS.default_port(uri_transport(uri))
    host = Util.unbracket(domain)

    ip =
      case :inet.parse_strict_address(String.to_charlist(host)) do
        {:ok, ip} -> ip
        {:error, _} -> nil
      end

    names = ["localhost" | Enum.filter([config[:local_host], config[:local_host6]], &is_binary/1)]

    Enum.any?(listeners(service), fn listener ->
      listener.local_port == port and (host in names or local_ip?(ip, listener.local_ip))
    end)
  end

  defp uri_transport(%URI{scheme: scheme} = uri) do
    case URI.get_param(uri, "transport") do
      {:ok, transport} when is_binary(transport) -> known_transport(String.downcase(transport))
      _ when scheme == :sips -> :tls
      _ -> :udp
    end
  end

  for transport <- [:udp, :tcp, :tls, :sctp, :ws, :wss] do
    defp known_transport(unquote(Atom.to_string(transport))), do: unquote(transport)
  end

  defp known_transport(_other), do: :udp

  defp local_ip?(nil, _listen_ip), do: false
  defp local_ip?(ip, ip), do: true

  defp local_ip?(ip, listen_ip) when listen_ip in [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}] do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        Enum.any?(ifaces, fn {_, opts} -> ip in Keyword.get_values(opts, :addr) end)

      _ ->
        false
    end
  end

  defp local_ip?(_ip, _listen_ip), do: false

  @doc "Returns the listening ports of a listener started with `start_listener/3`."
  @spec listener_ports(pid()) :: [Port.t()]
  def listener_ports(pid) do
    for {_id, child, _type, _modules} <- Supervisor.which_children(pid),
        is_pid(child),
        key <- Registry.keys(@listeners, child),
        {^child, port} <- Registry.lookup(@listeners, key),
        do: port
  end

  @doc false
  def register_listener(%Port{} = port) do
    {:ok, _} = Registry.register(@listeners, {port.service, port.transport}, port)
    :ok
  end

  ## ===================================================================
  ## Connections
  ## ===================================================================

  @doc "Returns the TCP, TLS, WS and WSS connections of a service."
  @spec connections(term()) :: [Port.t()]
  def connections(service) do
    Registry.select(@connections, [
      {{{:"$1", :_, :_, :_, :_}, :_, :"$2"}, [{:==, :"$1", {:const, service}}], [:"$2"]}
    ])
  end

  @doc """
  Returns the shared connections to a peer (at most one), excluding the ones
  started with `new_connection: true`.
  """
  @spec get_connected(term(), Port.transport(), :inet.ip_address(), :inet.port_number()) :: [
          Port.t()
        ]
  def get_connected(service, transport, ip, port) do
    for {_pid, conn} <- Registry.lookup(@connections, {service, transport, ip, port, :shared}),
        do: conn
  end

  @doc "Returns the port of a listener process."
  @spec listener_port(pid()) :: {:ok, Port.t()} | :error
  def listener_port(pid) do
    with [key | _] <- Registry.keys(@listeners, pid),
         [port | _] <- for({^pid, port} <- Registry.lookup(@listeners, key), do: port) do
      {:ok, port}
    else
      _ -> :error
    end
  end

  @doc "Returns the port of a TCP, TLS, WS or WSS connection process."
  @spec connection_port(pid()) :: {:ok, Port.t()} | :error
  def connection_port(pid) do
    with [key | _] <- Registry.keys(@connections, pid),
         [{^pid, port} | _] <- Registry.lookup(@connections, key) do
      {:ok, port}
    else
      _ -> :error
    end
  end

  @doc false
  def register_connection(%Port{} = port, tag) do
    case Registry.register(@connections, connection_key(port, tag), port) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def update_connection(%Port{} = port, tag) do
    {_new, _old} =
      Registry.update_value(@connections, connection_key(port, tag), fn _ -> port end)

    :ok
  end

  defp connection_key(port, tag),
    do: {port.service, port.transport, port.remote_ip, port.remote_port, tag}

  ## ===================================================================
  ## Sending
  ## ===================================================================

  @doc """
  Sends data (or a message) through an existing UDP port with a peer or a
  connection, usually the one a message was received from.
  """
  @spec send(Port.t(), iodata() | Message.t()) :: {:ok, Port.t()} | {:error, term()}
  def send(%Port{} = port, data) do
    with {:ok, port, _} <- send_message(port, fn _ -> data end), do: {:ok, port}
  end

  @doc """
  Sends data (or a message) to a target: a URI (resolved following
  RFC 3263, trying each destination in order until one works) or a
  `{transport, ip, port}` tuple.

  A listener for the transport (and IP family) is required. Returns the
  port used, whose `listen_ip` and `listen_port` are those of the listener.

  Options:

    * `:new_connection` - open a new, dedicated connection instead of
      reusing an existing one.
    * `:udp_max_size` - messages over UDP larger than this (the maximum
      datagram size by default) fail with `:udp_too_large`, or go over TCP if
      `:udp_to_tcp` is `true`.
    * `:idle_timeout` and `:connect_timeout` - for new connections.
    * `:tls` - `:ssl` client options, merged with the defaults (peer
      verification against the system CAs and, when the target is a URI with
      a host name, hostname checking).
    * `:ws_path` - HTTP path for new WS and WSS connections, the path of the
      target URI or `/` by default.
    * DNS options, see `Caracola.DNS.resolve/2`.
  """
  @spec send(term(), target(), iodata() | Message.t(), keyword()) ::
          {:ok, Port.t()} | {:error, term()}
  def send(service, target, data, opts \\ []) do
    with {:ok, port, _} <- send_message(service, target, fn _ -> data end, opts), do: {:ok, port}
  end

  @doc """
  Like `send/2`, but the message is generated by `make`, called with the
  port it will be sent through. Returns the port and the generated message.
  """
  @spec send_message(Port.t(), (Port.t() -> iodata() | Message.t())) ::
          {:ok, Port.t(), iodata() | Message.t()} | {:error, term()}
  def send_message(%Port{remote_ip: ip} = port, make) when ip != nil do
    msg = make.(port)
    transmit(port, msg)
  end

  @doc """
  Like `send/4`, but the message is generated by `make`, called with the
  port it will be sent through (for new connections, the listener port with
  the remote address). As the transport may change (UDP to TCP, or another
  destination after a failure), `make` can be called several times.
  """
  @spec send_message(term(), target(), (Port.t() -> iodata() | Message.t()), keyword()) ::
          {:ok, Port.t(), iodata() | Message.t()} | {:error, term()}
  def send_message(service, target, make, opts \\ [])

  def send_message(service, {transport, ip, port}, make, opts),
    do: send_to(service, {transport, ip, port}, make, opts)

  def send_message(service, target, make, opts) do
    with {:ok, uris} <- parse_target(target),
         {:ok, targets} <- DNS.resolve(uris, opts),
         do: send_first(service, targets, make, uri_opts(opts, uris), {:error, :no_targets})
  end

  # RFC 3263 failover: tries each target until one works
  defp send_first(_service, [], _make, _opts, last_error), do: last_error

  defp send_first(service, [target | rest], make, opts, _last_error) do
    case send_to(service, target, make, opts) do
      {:ok, port, msg} -> {:ok, port, msg}
      {:error, reason} -> send_first(service, rest, make, opts, {:error, reason})
    end
  end

  # The host name is used to check TLS certificates (and as Host in the
  # WebSocket handshake), and the path for the WebSocket handshake
  defp uri_opts(opts, [%URI{domain: domain, path: path} | _]) do
    opts = if path, do: Keyword.put_new(opts, :ws_path, path), else: opts

    case :inet.parse_address(String.to_charlist(Util.unbracket(domain))) do
      {:ok, _ip} -> opts
      {:error, _} -> Keyword.put_new(opts, :host, domain)
    end
  end

  defp parse_target(%URI{} = uri), do: {:ok, [uri]}

  defp parse_target(bin) when is_binary(bin) do
    case URI.parse(bin) do
      {:ok, uris} -> {:ok, uris}
      :error -> {:error, {:invalid_uri, bin}}
    end
  end

  defp parse_target(other), do: {:error, {:invalid_uri, other}}

  defp send_to(service, {:udp, ip, port}, make, opts) do
    with {:ok, listener} <- find_listener(service, :udp, ip),
         do: send_udp(service, %{listener | remote_ip: ip, remote_port: port}, make, opts)
  end

  defp send_to(service, {transport, ip, port}, make, opts)
       when transport in @connection_transports do
    existing = if opts[:new_connection], do: [], else: get_connected(service, transport, ip, port)

    case existing do
      [conn | _] ->
        transmit(conn, make.(conn))

      [] ->
        connect_send(service, transport, ip, port, make, opts)
    end
  end

  defp send_to(_service, {transport, _ip, _port}, _make, _opts),
    do: {:error, {:unsupported_transport, transport}}

  defp send_udp(service, udp, make, opts) do
    msg = make.(udp)
    data = encode(msg)

    cond do
      IO.iodata_length(data) <= Keyword.get(opts, :udp_max_size, @max_udp) ->
        transmit(udp, msg, data)

      opts[:udp_to_tcp] ->
        send_to(service, {:tcp, udp.remote_ip, udp.remote_port}, make, opts)

      true ->
        {:error, :udp_too_large}
    end
  end

  defp connect_send(service, transport, ip, port, make, opts) do
    with {:ok, base} <- find_listener(service, transport, ip) do
      opts = Keyword.put_new(opts, :idle_timeout, @default_idle_timeout)
      base = %{base | socket: nil, remote_ip: ip, remote_port: port}
      sup = {:via, PartitionSupervisor, {@connection_sup, {ip, port}}}

      sup
      |> DynamicSupervisor.start_child({Connection, {base, ip, port, opts}})
      |> connected(service, base, make, opts)
    end
  end

  defp connected({:ok, pid}, _service, base, make, opts) do
    msg = make.(%{base | pid: pid})
    data = encode(msg)

    with {:ok, conn} <- call_send(pid, data, opts) do
      Caracola.Telemetry.sent(conn, msg, data)
      {:ok, conn, msg}
    end
  end

  # Another process started the connection at the same time
  defp connected(:ignore, service, base, make, opts) do
    target = {base.transport, base.remote_ip, base.remote_port}
    send_to(service, target, make, Keyword.delete(opts, :new_connection))
  end

  defp connected({:error, {:shutdown, reason}}, _service, _base, _make, _opts),
    do: {:error, reason}

  defp connected({:error, reason}, _service, _base, _make, _opts), do: {:error, reason}

  defp find_listener(service, transport, ip) do
    size = tuple_size(ip)

    case Enum.find(listeners(service, transport), &(tuple_size(&1.local_ip) == size)) do
      nil -> {:error, :no_listening_transport}
      listener -> {:ok, listener}
    end
  end

  defp transmit(port, msg, data \\ nil) do
    data = data || encode(msg)

    with {:ok, port} <- port_send(port, data) do
      Caracola.Telemetry.sent(port, msg, data)
      {:ok, port, msg}
    end
  end

  defp port_send(
         %Port{transport: :udp, socket: socket, remote_ip: ip, remote_port: port} = udp,
         data
       ) do
    with :ok <- :gen_udp.send(socket, ip, port, data), do: {:ok, udp}
  end

  # Data is written to the socket from the calling process: a call process
  # must never wait for a connection process, which may be waiting to deliver
  # a message to it. The connection is told to restart its idle timer.
  defp port_send(%Port{socket: socket, pid: pid} = conn, data) when socket != nil do
    with :ok <- raw_send(conn, data) do
      Kernel.send(pid, :touch)
      {:ok, conn}
    end
  end

  # Still connecting
  defp port_send(%Port{pid: pid}, data), do: call_send(pid, data, [])

  # Incoming connections are ThousandIsland sockets. Over WebSocket, each
  # message goes in a frame.
  defp raw_send(%Port{transport: transport, socket: %ThousandIsland.Socket{} = socket}, data)
       when transport in [:ws, :wss],
       do: ThousandIsland.Socket.send(socket, WS.frame(data, :server))

  defp raw_send(%Port{socket: %ThousandIsland.Socket{} = socket}, data),
    do: ThousandIsland.Socket.send(socket, data)

  defp raw_send(%Port{transport: :tcp, socket: socket}, data), do: :gen_tcp.send(socket, data)
  defp raw_send(%Port{transport: :tls, socket: socket}, data), do: :ssl.send(socket, data)

  defp raw_send(%Port{transport: :ws, socket: socket}, data),
    do: :gen_tcp.send(socket, WS.frame(data, :client))

  defp raw_send(%Port{transport: :wss, socket: socket}, data),
    do: :ssl.send(socket, WS.frame(data, :client))

  defp call_send(pid, data, opts) do
    GenServer.call(pid, {:send, data}, Keyword.get(opts, :connect_timeout, 5_000) + 5_000)
  catch
    :exit, reason -> {:error, {:connection_down, reason}}
  end

  defp encode(%Message{} = msg), do: Serializer.to_iodata(msg)
  defp encode(data), do: data

  defp to_ip(ip) when is_tuple(ip), do: {:ok, ip}

  defp to_ip(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, {:invalid_ip, ip}}
    end
  end
end
