defmodule Caracola.WSTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.Test.{Client, Server}
  alias Caracola.{Transport, UAC, URI}
  alias Caracola.Transport.Port

  import Caracola.Test.Helpers

  # Adapted from NkSIP's t23_ws: SIP over WebSocket (RFC 7118)

  defp ws_port(service) do
    [%Port{local_port: port}] = Transport.listeners(service, :ws)
    port
  end

  test "dialog over ws" do
    listen = "sip:127.0.0.1:0, <sip:127.0.0.1:0/sip;transport=ws>"
    start([listen: listen], listen: listen)
    uri = "<sip:127.0.0.1:#{ws_port(Server)}/sip;transport=ws>"

    assert {:ok, 200, []} = UAC.options(Client, uri)
    assert [%Port{transport: :ws}] = Transport.connections(Server)

    assert {:ok, 200, [dialog: dialog, contacts: [contact]]} =
             UAC.invite(Client, uri, [{:add, "x-op", "ok"}, get_meta: [:contacts]])

    assert %URI{port: port, params: [{"transport", "ws"}]} = contact
    assert port == ws_port(Server)
    assert UAC.ack(dialog) == :ok
    assert {:ok, 200, []} = UAC.bye(dialog)

    # Only WebSocket connections were used
    assert [%Port{transport: :ws}] = Transport.connections(Client)
  end
end
