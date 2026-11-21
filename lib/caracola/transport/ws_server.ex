defmodule Caracola.Transport.WSServer do
  @moduledoc false
  # WS and WSS listener (ThousandIsland). Each accepted connection waits for
  # the opening handshake and then registers itself in the connection table,
  # so that it can be reused to send requests to the same peer.

  use ThousandIsland.Handler

  alias Caracola.Transport
  alias Caracola.Transport.{Port, WS}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {:ok, {remote_ip, remote_port}} = ThousandIsland.Socket.peername(socket)
    {:ok, {local_ip, local_port}} = ThousandIsland.Socket.sockname(socket)

    port = %Port{
      service: state.service,
      transport: state.transport,
      local_ip: local_ip,
      local_port: local_port,
      remote_ip: remote_ip,
      remote_port: remote_port,
      listen_ip: state.listen_ip,
      listen_port: local_port,
      pid: self(),
      socket: socket,
      handler: state.handler
    }

    {:continue,
     %{
       port: port,
       path: state.path,
       ws: nil,
       buffer: "",
       idle_timeout: state.idle_timeout,
       timer: start_timer(nil, state.idle_timeout)
     }}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{ws: nil} = state) do
    buffer = state.buffer <> data

    case WS.server_handshake(buffer, state.path) do
      {:ok, response, rest} ->
        ThousandIsland.Socket.send(socket, response)

        # A connection with the same peer may already exist (an outgoing one)
        with {:error, _} <- Transport.register_connection(state.port, :shared),
             do: Transport.register_connection(state.port, make_ref())

        handle_data(rest, socket, %{state | ws: WS.new(:server), buffer: ""})

      {:error, response} ->
        ThousandIsland.Socket.send(socket, response)
        {:close, state}

      :partial ->
        {:continue, touch(%{state | buffer: buffer})}
    end
  end

  def handle_data(data, socket, state) do
    case WS.handle_data(data, state.ws, state.port, &ThousandIsland.Socket.send(socket, &1)) do
      {:ok, ws} -> {:continue, touch(%{state | ws: ws})}
      {:close, _reason} -> {:close, state}
    end
  end

  @impl GenServer
  def handle_call({:send, data}, _from, {socket, state}) do
    reply =
      with :ok <- ThousandIsland.Socket.send(socket, WS.frame(data, :server)),
           do: {:ok, state.port}

    {:reply, reply, {socket, touch(state)}}
  end

  @impl GenServer
  def handle_info(:touch, {socket, state}), do: {:noreply, {socket, touch(state)}}

  def handle_info(:idle_timeout, {socket, state}) do
    ThousandIsland.Socket.close(socket)
    {:stop, :normal, {socket, state}}
  end

  defp touch(state), do: %{state | timer: start_timer(state.timer, state.idle_timeout)}

  defp start_timer(timer, timeout) do
    if timer, do: Process.cancel_timer(timer)
    Process.send_after(self(), :idle_timeout, timeout)
  end
end
