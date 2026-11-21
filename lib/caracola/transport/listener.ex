defmodule Caracola.Transport.Listener do
  @moduledoc false
  # Supervisor for a listener: a UDP socket plus a TCP listener on the same
  # port (RFC 3261 §18 requires both), or a TCP, TLS, WS or WSS listener.
  # Children are restarted together.

  use Supervisor, restart: :temporary

  alias Caracola.Transport.{TCP, UDP, WSServer}

  @retries 5

  def start_link({service, transport, opts}) do
    if transport == :udp and opts[:port] == 0,
      do: start_random(service, opts, @retries),
      else: Supervisor.start_link(__MODULE__, {service, transport, opts})
  end

  # UDP and TCP must share the port: we look for one that is free for both,
  # and try again if it is taken before the listeners are started
  defp start_random(service, opts, retries) do
    opts = Keyword.put(opts, :port, free_port(opts[:ip]))

    case Supervisor.start_link(__MODULE__, {service, :udp, opts}) do
      {:error, _} when retries > 1 -> start_random(service, opts, retries - 1)
      other -> other
    end
  end

  defp free_port(ip) do
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet
    {:ok, udp} = :gen_udp.open(0, [family, ip: ip])
    {:ok, {_ip, port}} = :inet.sockname(udp)

    case :gen_tcp.listen(port, [family, ip: ip, reuseaddr: true]) do
      {:ok, tcp} ->
        :gen_tcp.close(tcp)
        :gen_udp.close(udp)
        port

      {:error, _} ->
        port = free_port(ip)
        :gen_udp.close(udp)
        port
    end
  end

  @impl true
  def init({service, :udp, opts}) do
    name = server_name()

    children = [
      {UDP, {service, opts}},
      tcp_spec(service, :tcp, name, opts),
      {__MODULE__.Registrar, {service, :tcp, name, opts}}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def init({service, transport, opts}) do
    name = server_name()

    children = [
      tcp_spec(service, transport, name, opts),
      {__MODULE__.Registrar, {service, transport, name, opts}}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  # ThousandIsland server, registered under `name` so that the registrar
  # (started after it in the listener supervisor) can find its port
  defp tcp_spec(service, transport, name, opts) do
    ip = Keyword.fetch!(opts, :ip)
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet

    {module, transport_opts} =
      if transport in [:tls, :wss],
        do: {ThousandIsland.Transports.SSL, Keyword.get(opts, :tls, [])},
        else: {ThousandIsland.Transports.TCP, []}

    state = %{
      service: service,
      transport: transport,
      handler: Keyword.get(opts, :handler),
      idle_timeout: Keyword.fetch!(opts, :idle_timeout),
      listen_ip: ip,
      path: Keyword.get(opts, :path)
    }

    [
      port: Keyword.fetch!(opts, :port),
      transport_module: module,
      transport_options: [family, ip: ip, reuseaddr: true] ++ transport_opts,
      handler_module: if(transport in [:ws, :wss], do: WSServer, else: TCP),
      handler_options: state,
      num_acceptors: Keyword.get(opts, :num_acceptors, 10),
      read_timeout: :infinity,
      supervisor_options: [name: name]
    ]
    |> ThousandIsland.child_spec()
    |> Map.put(:id, {TCP, transport})
  end

  defp server_name do
    {:via, Registry, {Caracola.Transport.Names, make_ref()}}
  end
end

defmodule Caracola.Transport.Listener.Registrar do
  @moduledoc false
  # Registers a TCP or TLS listener in the listener table, once its port is
  # known. The registration lives as long as this process.

  use GenServer

  alias Caracola.Transport
  alias Caracola.Transport.Port

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({service, transport, name, opts}) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(name)
    ip = Keyword.fetch!(opts, :ip)

    Transport.register_listener(%Port{
      service: service,
      transport: transport,
      local_ip: ip,
      local_port: port,
      listen_ip: ip,
      listen_port: port,
      pid: GenServer.whereis(name),
      handler: Keyword.get(opts, :handler)
    })

    {:ok, nil}
  end
end
