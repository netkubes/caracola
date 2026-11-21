defmodule Caracola.Transport.Connection do
  @moduledoc false
  # Outgoing TCP, TLS, WS or WSS connection. It registers itself in the
  # connection table before connecting, so that concurrent senders to the
  # same peer find it and queue their messages until it is connected (and,
  # for WebSocket, the opening handshake is done).

  use GenServer, restart: :temporary

  alias Caracola.Transport
  alias Caracola.Transport.{Port, Stream, WS}

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({%Port{} = base, ip, remote_port, opts}) do
    port = %Port{base | pid: self(), remote_ip: ip, remote_port: remote_port, socket: nil}
    tag = if opts[:new_connection], do: make_ref(), else: :shared

    case Transport.register_connection(port, tag) do
      :ok -> connect(port, tag, opts)
      {:error, {:already_registered, _pid}} -> :ignore
    end
  end

  defp connect(port, tag, opts) do
    family = if tuple_size(port.remote_ip) == 8, do: :inet6, else: :inet
    sock_opts = [:binary, family, active: false, packet: :raw, nodelay: true]
    timeout = Keyword.get(opts, :connect_timeout, 5_000)

    result =
      if port.transport in [:tls, :wss],
        do: :ssl.connect(port.remote_ip, port.remote_port, sock_opts ++ tls_opts(opts), timeout),
        else: :gen_tcp.connect(port.remote_ip, port.remote_port, sock_opts, timeout)

    with {:ok, socket} <- result,
         port = %{port | socket: socket},
         {:ok, {local_ip, local_port}} <- sockname(port),
         {:ok, ws, buffer} <- handshake(port, opts, timeout) do
      port = %{port | local_ip: local_ip, local_port: local_port}
      Transport.update_connection(port, tag)
      idle_timeout = Keyword.fetch!(opts, :idle_timeout)
      setopts(port, active: :once)

      state = %{
        port: port,
        ws: ws,
        buffer: "",
        idle_timeout: idle_timeout,
        timer: start_timer(nil, idle_timeout)
      }

      # Data received after the handshake
      case buffer do
        "" -> {:ok, state}
        _ -> {:ok, state, {:continue, {:data, buffer}}}
      end
    else
      {:error, reason} -> {:stop, {:shutdown, reason}}
    end
  end

  # Peer verification against the system CAs by default. The host name is
  # checked if known (when the destination was a URI with a host name)
  defp tls_opts(opts) do
    host = Keyword.get(opts, :host)

    defaults =
      [verify: :verify_peer, cacerts: :public_key.cacerts_get()] ++
        if host,
          do: [
            server_name_indication: String.to_charlist(host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ],
          else: [server_name_indication: :disable]

    Keyword.merge(defaults, Keyword.get(opts, :tls, []))
  end

  # WebSocket opening handshake (RFC 7118 requires the "sip" subprotocol)
  defp handshake(%Port{transport: transport} = port, opts, timeout)
       when transport in [:ws, :wss] do
    host = Keyword.get_lazy(opts, :host, fn -> host(port.remote_ip) end)
    {key, request} = WS.client_request(host, Keyword.get(opts, :ws_path, "/"))

    with :ok <- send_raw(port, request),
         {:ok, rest} <- recv_handshake(port, key, "", timeout),
         do: {:ok, WS.new(:client), rest}
  end

  defp handshake(_port, _opts, _timeout), do: {:ok, nil, ""}

  defp recv_handshake(port, key, buffer, timeout) do
    recv =
      if port.transport == :wss,
        do: :ssl.recv(port.socket, 0, timeout),
        else: :gen_tcp.recv(port.socket, 0, timeout)

    with {:ok, data} <- recv do
      case WS.client_response(buffer <> data, key) do
        :partial -> recv_handshake(port, key, buffer <> data, timeout)
        other -> other
      end
    end
  end

  defp host({_, _, _, _} = ip), do: List.to_string(:inet.ntoa(ip))
  defp host(ip), do: "[#{:inet.ntoa(ip)}]"

  @impl true
  def handle_continue({:data, data}, state), do: data(data, state)

  @impl true
  def handle_call({:send, data}, _from, state) do
    reply = with :ok <- send_data(state.port, data), do: {:ok, state.port}
    {:reply, reply, touch(state)}
  end

  @impl true
  def handle_info({tag, socket, data}, %{port: %{socket: socket}} = state)
      when tag in [:tcp, :ssl] do
    setopts(state.port, active: :once)
    data(data, state)
  end

  def handle_info({tag, socket}, %{port: %{socket: socket}} = state)
      when tag in [:tcp_closed, :ssl_closed],
      do: {:stop, :normal, state}

  def handle_info({tag, socket, reason}, %{port: %{socket: socket}} = state)
      when tag in [:tcp_error, :ssl_error],
      do: {:stop, {:shutdown, reason}, state}

  def handle_info(:touch, state), do: {:noreply, touch(state)}

  # Pongs go to the keepalive process of the flow
  def handle_info({:keepalive_subscribe, pid}, state),
    do: {:noreply, Map.put(state, :keepalive, pid)}

  def handle_info(:keepalive_pong, state) do
    if pid = state[:keepalive], do: send(pid, :keepalive_pong)
    {:noreply, state}
  end

  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if port.transport in [:tls, :wss],
      do: :ssl.close(port.socket),
      else: :gen_tcp.close(port.socket)
  end

  defp data(data, %{ws: nil} = state) do
    case Stream.handle_data(data, state.buffer, state.port, &send_raw(state.port, &1)) do
      {:ok, buffer} -> {:noreply, touch(%{state | buffer: buffer})}
      {:close, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end

  defp data(data, state) do
    case WS.handle_data(data, state.ws, state.port, &send_raw(state.port, &1)) do
      {:ok, ws} -> {:noreply, touch(%{state | ws: ws})}
      {:close, :normal} -> {:stop, :normal, state}
      {:close, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end

  # SIP messages, framed for WebSocket
  defp send_data(%Port{transport: transport} = port, data) when transport in [:ws, :wss],
    do: send_raw(port, WS.frame(data, :client))

  defp send_data(port, data), do: send_raw(port, data)

  defp send_raw(%Port{transport: transport, socket: socket}, data)
       when transport in [:tls, :wss],
       do: :ssl.send(socket, data)

  defp send_raw(%Port{socket: socket}, data), do: :gen_tcp.send(socket, data)

  defp setopts(%Port{transport: transport, socket: socket}, opts)
       when transport in [:tls, :wss],
       do: :ssl.setopts(socket, opts)

  defp setopts(%Port{socket: socket}, opts), do: :inet.setopts(socket, opts)

  defp sockname(%Port{transport: transport, socket: socket}) when transport in [:tls, :wss],
    do: :ssl.sockname(socket)

  defp sockname(%Port{socket: socket}), do: :inet.sockname(socket)

  defp touch(state), do: %{state | timer: start_timer(state.timer, state.idle_timeout)}

  defp start_timer(timer, timeout) do
    if timer, do: Process.cancel_timer(timer)
    Process.send_after(self(), :idle_timeout, timeout)
  end
end
