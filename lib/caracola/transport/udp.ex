defmodule Caracola.Transport.UDP do
  @moduledoc false
  # UDP listener. Owns the socket and hands each datagram to one of its
  # workers (one per scheduler), chosen by the Call-ID, which parse and
  # dispatch them: messages of different calls are processed in parallel,
  # and the ones of the same call in order. There are no per-peer
  # processes: messages are sent directly through the listener socket, so
  # that responses come from the listening port.

  use GenServer, restart: :permanent

  alias Caracola.{Parser, Serializer}
  alias Caracola.Transport
  alias Caracola.Transport.{Handler, Port, Stun}

  @active_n 100

  def start_link({service, opts}), do: GenServer.start_link(__MODULE__, {service, opts})

  @impl true
  def init({service, opts}) do
    ip = Keyword.fetch!(opts, :ip)
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet
    sock_opts = [:binary, family, ip: ip, active: @active_n, recbuf: 1_048_576, sndbuf: 1_048_576]

    case :gen_udp.open(Keyword.fetch!(opts, :port), sock_opts) do
      {:ok, socket} ->
        {:ok, {local_ip, local_port}} = :inet.sockname(socket)

        port = %Port{
          service: service,
          transport: :udp,
          local_ip: local_ip,
          local_port: local_port,
          listen_ip: local_ip,
          listen_port: local_port,
          pid: self(),
          socket: socket,
          handler: Keyword.get(opts, :handler)
        }

        Transport.register_listener(port)
        workers = for _ <- 1..System.schedulers_online(), do: spawn_link(&worker/0)
        {:ok, %{port: port, workers: List.to_tuple(workers), call_id: call_id_regex()}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:udp, _socket, ip, remote_port, data}, %{port: port} = state) do
    cond do
      # Keepalives: only CRLFs, or STUN (RFC 5626 §4.4.2)
      String.trim(data, "\r\n") == "" ->
        :ok

      Stun.stun?(data) ->
        stun(data, ip, remote_port, port)

      true ->
        port = %{port | remote_ip: ip, remote_port: remote_port}
        send(worker(data, state), {:datagram, data, port})
    end

    {:noreply, state}
  end

  def handle_info({:udp_passive, socket}, state) do
    :ok = :inet.setopts(socket, active: @active_n)
    {:noreply, state}
  end

  # The worker of a datagram, by its Call-ID (if it is not found, by the
  # whole datagram: it is invalid, and will be answered with a 400)
  defp worker(data, %{workers: workers, call_id: regex}) do
    key =
      case Regex.run(regex, data, capture: :all_but_first) do
        [call_id] -> call_id
        _ -> data
      end

    elem(workers, :erlang.phash2(key, tuple_size(workers)))
  end

  defp call_id_regex, do: Regex.compile!("\r\n(?:call-id|i)[ \t]*:[ \t]*([^\r\n]+)", "i")

  defp worker do
    receive do
      {:datagram, data, port} -> process(data, port)
    end

    worker()
  end

  # Binding requests are answered, and responses go to the process waiting
  # for them (see Caracola.Transport.Keepalive)
  defp stun(data, ip, remote_port, port) do
    case Stun.decode(data) do
      {:request, tid} ->
        :gen_udp.send(port.socket, ip, remote_port, Stun.response(tid, ip, remote_port))

      {:response, tid, mapped} ->
        for {pid, _} <- Registry.lookup(Caracola.Transport.Names, {:stun, tid}),
            do: send(pid, {:stun_response, tid, mapped})

      :error ->
        :ok
    end
  end

  defp process(data, port) do
    case Parser.parse(data, :udp) do
      {:ok, msg, _rest} ->
        Handler.dispatch(port, msg, byte_size(data))

      {:error, error} ->
        with {:ok, reply} <- Serializer.error_response(error),
             do: :gen_udp.send(port.socket, port.remote_ip, port.remote_port, reply)
    end
  end
end
