defmodule Caracola.AutoOutboundTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Registrar, Transport, UACAutoOutbound, UACAutoRegister}
  alias Caracola.Test.{ObRegistrar, ObUA3}
  alias Caracola.Transport.{Keepalive, Port, Stun}

  import Caracola.Test.Helpers

  # Ported and adapted from the uac_auto/0 test of NkSIP's t21_outbound

  setup do
    on_exit(fn -> Registrar.clear(ObRegistrar) end)
    rport = start_service(ObRegistrar)
    start_service(ObUA3)
    %{rport: rport}
  end

  defp registers, do: Enum.sort(UACAutoRegister.get_registers(ObUA3))

  defp wait_registered(retries \\ 40) do
    case registers() do
      [{:auto1, true, _}, {:auto2, true, _}] ->
        :ok

      _ when retries > 0 ->
        Process.sleep(250)
        wait_registered(retries - 1)

      other ->
        flunk("not registered: #{inspect(other)}")
    end
  end

  test "stun" do
    {tid, request} = Stun.request()
    assert Stun.stun?(request)
    assert Stun.decode(request) == {:request, tid}

    assert Stun.decode(Stun.response(tid, {10, 0, 0, 1}, 5060)) ==
             {:response, tid, {{10, 0, 0, 1}, 5060}}

    ip6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
    assert Stun.decode(Stun.response(tid, ip6, 5070)) == {:response, tid, {ip6, 5070}}
    refute Stun.stun?("OPTIONS sip:a SIP/2.0\r\n\r\n")
  end

  test "registrations", %{rport: rport} do
    assert UACAutoOutbound.start_register(ObUA3, :auto1, "<sip:127.0.0.1:#{rport};transport=tcp>") ==
             {:ok, true}

    assert UACAutoOutbound.start_register(ObUA3, :auto2, "<sip:127.0.0.1:#{rport};transport=udp>") ==
             {:ok, true}

    assert [{:auto1, true, _}, {:auto2, true, _}] = registers()

    assert [{:auto1, true, _, 0}, {:auto2, true, _, 0}] =
             Enum.sort(UACAutoOutbound.get_registers(ObUA3))

    # Two registrations, with different reg-ids
    assert [{:ob, id, "2"}, {:ob, id, "1"}] =
             Enum.map(Registrar.get_info(ObRegistrar, {:sip, "ob_ua3", "caracola"}), & &1.index)

    # Keepalives of the flows: TCP every 120 secs (minus up to 20%), UDP 25
    keepalives = Map.new(UACAutoOutbound.get_keepalives(ObUA3))
    assert Keepalive.secs(keepalives.auto1) in 96..120
    assert Keepalive.secs(keepalives.auto2) in 20..25

    # The TCP flow fails: registered again after the backoff (2-4 secs)
    [%Port{pid: conn}] = Transport.connections(ObUA3)
    Process.exit(conn, :kill)
    eventually(fn -> match?([{:auto1, false, _}, {:auto2, true, _}], registers()) end)
    assert [{:auto1, false, _, 1}, _] = Enum.sort(UACAutoOutbound.get_registers(ObUA3))
    wait_registered()

    # Unregistered when the service stops
    stop_supervised!(ObUA3)
    assert Registrar.get_info(ObRegistrar, {:sip, "ob_ua3", "caracola"}) == []
  end

  test "keepalives", %{rport: rport} do
    # A STUN keepalive answered by the registrar
    {:ok, udp} = Transport.listener_port(listener_pid(ObUA3))
    port = %{udp | remote_ip: {127, 0, 0, 1}, remote_port: rport}
    {:ok, pid} = Keepalive.start_link(port, 1, self())
    assert_receive {:keepalive_ok, ^pid}, 2000
    assert_receive {:keepalive_ok, ^pid}, 2000

    # CRLF pings over TCP
    assert {:ok, 200, []} = Caracola.UAC.options(ObUA3, "<sip:127.0.0.1:#{rport};transport=tcp>")
    [%Port{pid: conn} = tcp] = Transport.connections(ObUA3)
    {:ok, pid} = Keepalive.start_link(tcp, 1, self())
    assert_receive {:keepalive_ok, ^pid}, 2000

    # The connection goes down
    Process.flag(:trap_exit, true)
    Process.exit(conn, :kill)
    assert_receive {:EXIT, ^pid, {:shutdown, :flow_failed}}
  end

  defp listener_pid(service) do
    [%Port{pid: pid}] = Transport.listeners(service, :udp)
    pid
  end
end
