defmodule Caracola.IPv6Test do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Message, Transport, UAC, URI}
  alias Caracola.Test.{Client, Location, Server}
  alias Caracola.Test.Proxy, as: TestProxy
  alias Caracola.Transport.Port

  import Caracola.Test.Helpers

  doctest Caracola.Util

  # Adapted from NkSIP's t24_ipv6

  @listen "sip:127.0.0.1:0, sip:[::1]:0"

  defp port6(service, transport) do
    [%Port{local_port: port}] =
      for p <- Transport.listeners(service, transport), tuple_size(p.local_ip) == 8, do: p

    port
  end

  test "dialog over ipv6" do
    start([listen: @listen], listen: @listen)

    for transport <- [:udp, :tcp] do
      uri = "<sip:[::1]:#{port6(Server, transport)};transport=#{transport}>"
      assert {:ok, 200, []} = UAC.options(Client, uri)

      assert {:ok, 200, [dialog: dialog, contacts: [contact]]} =
               UAC.invite(Client, uri, [{:add, "x-op", "ok"}, get_meta: [:contacts]])

      assert %URI{domain: "[::1]"} = contact
      assert UAC.ack(dialog) == :ok
      assert {:ok, 200, []} = UAC.bye(dialog)
    end
  end

  test "proxy between ipv6 and ipv4" do
    # The client only has IPv6, the server only IPv4
    start([listen: "sip:127.0.0.1:0"], listen: "sip:[::1]:0")
    start_service(TestProxy, sip: [listen: @listen], proxy: [opts: [:record_route]])
    Location.put(TestProxy, "server", "<sip:server@127.0.0.1:#{port(Server)};transport=tcp>")
    on_exit(fn -> Location.delete(TestProxy, "server") end)

    route = "<sip:[::1]:#{port6(TestProxy, :udp)};lr>"

    assert {:ok, 200, [dialog: dia, contacts: [contact]]} =
             UAC.invite(Client, "sip:server@caracola", [
               {:add, "x-op", "ok"},
               route: route,
               get_meta: [:contacts]
             ])

    assert %URI{domain: "127.0.0.1"} = contact

    # Each side has the proxy address it can reach in its route set
    {:ok, %Dialog{route_set: [%URI{domain: "[::1]", params: [{"lr", nil}]} = r1]}} =
      Dialog.get(dia)

    assert r1.port == port6(TestProxy, :udp)
    [dib] = Dialog.list(Server, elem(dia, 2))
    {:ok, %Dialog{route_set: [r2]}} = Dialog.get(dib)
    assert %URI{domain: "127.0.0.1", params: [{"transport", "tcp"}, {"lr", nil}]} = r2

    assert UAC.ack(dia) == :ok
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    assert {:ok, 200, []} = UAC.options(dib)
    assert_receive {Client, {:options, %Message{vias: [_, _]}}}
    assert {:ok, 200, []} = UAC.bye(dia)
    assert_receive {Server, {:bye, %Message{vias: [_, _]}}}
  end
end
