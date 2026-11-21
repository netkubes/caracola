defmodule Caracola.Transport.Keepalive do
  @moduledoc false
  # Keeps an outbound flow alive (RFC 5626 §4.4): CRLF pings over TCP and
  # TLS (§4.4.1) and STUN Binding requests over UDP (§4.4.2), every
  # `secs` seconds. The owner gets `{:keepalive_ok, pid}` after each
  # answer. The process stops with `{:shutdown, :flow_failed}` if an answer
  # does not arrive in 10 seconds, the mapped address of a UDP flow
  # changes, or the connection goes down.

  use GenServer

  alias Caracola.Transport
  alias Caracola.Transport.{Port, Stun}

  @answer_timeout 10_000

  def start_link(%Port{} = port, secs, owner),
    do: GenServer.start_link(__MODULE__, {port, secs, owner})

  @doc "The keepalive interval (secs) of a keepalive process."
  def secs(pid), do: GenServer.call(pid, :secs)

  @impl true
  def init({%Port{transport: transport} = port, secs, owner}) do
    if transport != :udp do
      Process.monitor(port.pid)
      send(port.pid, {:keepalive_subscribe, self()})
    end

    Process.send_after(self(), :ping, secs * 1000)
    {:ok, %{port: port, secs: secs, owner: owner, timer: nil, tid: nil, mapped: nil}}
  end

  @impl true
  def handle_call(:secs, _from, state), do: {:reply, state.secs, state}

  @impl true
  def handle_info(:ping, %{port: %Port{transport: :udp} = port} = state) do
    {tid, request} = Stun.request()
    {:ok, _} = Registry.register(Caracola.Transport.Names, {:stun, tid}, nil)
    Transport.send(port, request)
    {:noreply, wait(%{state | tid: tid})}
  end

  def handle_info(:ping, state) do
    case Transport.send(state.port, "\r\n\r\n") do
      {:ok, _} -> {:noreply, wait(state)}
      {:error, _} -> {:stop, {:shutdown, :flow_failed}, state}
    end
  end

  def handle_info({:stun_response, tid, mapped}, %{tid: tid} = state) do
    Registry.unregister(Caracola.Transport.Names, {:stun, tid})

    # A new mapped address means the NAT binding changed
    if state.mapped != nil and mapped != state.mapped,
      do: {:stop, {:shutdown, :flow_failed}, state},
      else: {:noreply, answered(%{state | tid: nil, mapped: mapped})}
  end

  def handle_info(:keepalive_pong, %{timer: timer} = state) when timer != nil,
    do: {:noreply, answered(state)}

  def handle_info(:answer_timeout, state) do
    # A connection without answers is closed
    if state.port.transport != :udp, do: send(state.port.pid, :idle_timeout)
    {:stop, {:shutdown, :flow_failed}, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state),
    do: {:stop, {:shutdown, :flow_failed}, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp wait(state),
    do: %{state | timer: Process.send_after(self(), :answer_timeout, @answer_timeout)}

  defp answered(state) do
    Process.cancel_timer(state.timer)
    send(state.owner, {:keepalive_ok, self()})
    Process.send_after(self(), :ping, state.secs * 1000)
    %{state | timer: nil}
  end
end
