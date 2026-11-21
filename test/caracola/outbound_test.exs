defmodule Caracola.OutboundTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Message, Registrar, Transport, UAC, URI, Util}
  alias Caracola.Registrar.Contact
  alias Caracola.Test.{Location, ObEdge, ObRegistrar, ObUA1, ObUA2}
  alias Caracola.Test.Proxy, as: TestProxy
  alias Caracola.Transport.Port

  import Caracola.Test.Helpers

  # Ported and adapted from NkSIP's t21_outbound

  setup do
    on_exit(fn -> Registrar.clear(ObRegistrar) end)
    for service <- [ObRegistrar, ObUA1, ObUA2], do: start_service(service)
    %{registrar: "sip:127.0.0.1:#{port(ObRegistrar)}"}
  end

  defp info, do: Registrar.get_info(ObRegistrar, {:sip, "ob_ua1", "caracola"})
  defp find, do: Registrar.find(ObRegistrar, :sip, "ob_ua1", "caracola")
  defp instance(service), do: ~s("#{service.get_config()[:sip][:instance_id]}")

  defp connection(service, transport, remote_port) do
    Enum.find(Transport.connections(service), fn port ->
      port.transport == transport and port.remote_port == remote_port
    end)
  end

  test "contact" do
    uri = "sip:127.0.0.1:#{port(ObUA1)}"
    opts = [:get_request, callback: callback()]

    assert {:ok, 603, []} = UAC.invite(ObUA2, uri, [{:add, "x-op", "decline"} | opts])
    assert_receive {:callback, {:req, %Message{contacts: [contact]}}}
    assert {:ok, nil} = URI.get_param(contact, "ob")
    assert URI.get_ext_param(contact, "+sip.instance") == {:ok, instance(ObUA2)}
    assert instance(ObUA1) != instance(ObUA2)

    # Only dialog-forming requests, and if outbound is supported
    assert {:ok, 603, []} =
             UAC.invite(ObUA2, uri, [{:add, "x-op", "decline"}, {:supported, ""} | opts])

    assert_receive {:callback, {:req, %Message{contacts: [contact]}}}
    assert URI.get_param(contact, "ob") == :error

    assert {:ok, 200, []} = UAC.options(ObUA2, uri, [:contact | opts])
    assert_receive {:callback, {:req, %Message{contacts: [contact]}}}
    assert URI.get_param(contact, "ob") == :error
  end

  test "flow", %{registrar: registrar} do
    # Without reg-id the registration does not use outbound, but as both
    # parties support it and the connection is direct, the registrar adds a
    # Path with the flow
    assert {:ok, 200, [{"require", []}, {:contacts, [contact]}]} =
             UAC.register(ObUA1, "<#{registrar};transport=tcp>", [
               :contact,
               get_meta: ["require", :contacts]
             ])

    assert URI.get_ext_param(contact, "+sip.instance") == {:ok, instance(ObUA1)}

    assert [%Contact{index: {:sip, "tcp", "ob_ua1", "127.0.0.1", _}, path: [path]}] = info()

    assert %URI{
             user: "NkF" <> _,
             port: rport,
             params: [{"transport", "tcp"}, {"lr", nil}, {"ob", nil}]
           } = path

    assert rport == port(ObRegistrar)
    [%Port{local_port: flow_port}] = Transport.connections(ObUA1)

    # Requests to the contact go to the registrar first, and then through
    # the same connection
    [found] = find()
    assert [{"route", _}] = found.headers
    assert {:ok, 200, []} = UAC.options(ObUA2, found)

    assert_receive {ObUA1,
                    {:options, %Message{vias: [_, _], port: %Port{local_port: ^flow_port}}}}

    # Without the flow token, the registrar opens a new connection
    route = URI.encode(%{path | user: nil}) |> IO.iodata_to_binary()
    no_flow = %{found | headers: [{"route", Elixir.URI.encode_www_form(route)}]}
    assert {:ok, 200, []} = UAC.options(ObUA2, no_flow)
    assert_receive {ObUA1, {:options, %Message{port: %Port{local_port: local}}}}
    assert local == port(ObUA1)

    # The flow fails
    %Port{pid: pid} = connection(ObRegistrar, :tcp, flow_port)
    Process.exit(pid, :kill)
    eventually(fn -> connection(ObRegistrar, :tcp, flow_port) == nil end)
    assert {:ok, 430, []} = UAC.options(ObUA2, found)

    # An invalid token
    bad = %{path | user: "NkFabc"} |> URI.encode() |> IO.iodata_to_binary()
    bad = %{found | headers: [{"route", Elixir.URI.encode_www_form(bad)}]}
    assert {:ok, 403, []} = UAC.options(ObUA2, bad)
  end

  test "register", %{registrar: registrar} do
    contacts =
      "<sip:a@a.com;ob>;+sip.instance=i;reg-id=1, <sip:b@a.com;ob>;+sip.instance=i;reg-id=2"

    assert {:ok, 400, [reason_phrase: "Several 'reg-id' Options"]} =
             UAC.register(ObUA1, registrar, contact: contacts, get_meta: [:reason_phrase])

    assert {:ok, 200, [{:contacts, [c1]}, {"require", ["outbound"]}]} =
             UAC.register(ObUA1, registrar, [
               :contact,
               reg_id: 1,
               get_meta: [:contacts, "require"]
             ])

    instance1 = instance(ObUA1)

    assert %URI{user: "ob_ua1", params: [], ext_params: ext} = c1
    assert [{"+sip.instance", ^instance1}, {"reg-id", "1"}, {"expires", "3600"}] = ext

    id1 = Util.hash(instance1)

    assert [
             %Contact{
               index: {:ob, ^id1, "1"},
               path: [%URI{user: "NkF" <> _, params: [{"lr", nil}, {"ob", nil}]}]
             }
           ] = info()

    # Another reg-id of the same instance
    assert {:ok, 200, [contacts: [_, _]]} =
             UAC.register(ObUA1, registrar, [:contact, reg_id: 2, get_meta: [:contacts]])

    # Another instance
    assert {:ok, 200, [contacts: [_, _, _]]} =
             UAC.register(ObUA2, registrar, [
               :contact,
               from: "<sip:ob_ua1@caracola>",
               reg_id: 1,
               get_meta: [:contacts]
             ])

    id2 = Util.hash(instance(ObUA2))

    assert [{:ob, ^id2, "1"}, {:ob, ^id1, "2"}, {:ob, ^id1, "1"}] =
             Enum.map(info(), & &1.index)

    # The same reg-id replaces the registration
    assert {:ok, 200, [contacts: [_, _, _]]} =
             UAC.register(ObUA1, registrar, [:contact, reg_id: 2, get_meta: [:contacts]])

    assert [{:ob, ^id1, "2"}, {:ob, ^id2, "1"}, {:ob, ^id1, "1"}] =
             Enum.map(info(), & &1.index)
  end

  test "edge proxy", %{registrar: registrar} do
    start_service(ObEdge)
    start_service(TestProxy, proxy: [opts: [:path]])
    Location.put(ObEdge, "reg", registrar)
    Location.put(TestProxy, "reg", registrar)

    on_exit(fn ->
      Location.delete(ObEdge, "reg")
      Location.delete(TestProxy, "reg")
    end)

    # The edge proxy is the first hop: it adds a Path with the flow
    assert {:ok, 200, [{"require", ["outbound"]}]} =
             UAC.register(ObUA1, "sip:reg@caracola", [
               :contact,
               reg_id: 1,
               route: route(ObEdge),
               get_meta: ["require"]
             ])

    [found] = find()
    assert [%Contact{path: [%URI{user: "NkF" <> flow} = path]}] = info()
    assert path.port == port(ObEdge)
    assert path.params == [{"lr", nil}, {"ob", nil}]

    # Requests go through the edge proxy and the flow
    assert {:ok, 200, []} = UAC.options(ObUA2, found)
    assert_receive {ObEdge, {:route, :options}}
    assert_receive {ObUA1, {:options, %Message{vias: [_, _]}}}

    # The dialog keeps using the flow (the edge proxy records the same token)
    assert {:ok, 200, [dialog: dialog]} =
             UAC.invite(ObUA2, found, [{:add, "x-op", "ok"}, :auto_2xx_ack])

    {:ok, %{route_set: route_set}} = Caracola.Dialog.get(dialog)
    assert [%URI{user: "NkF" <> ^flow, port: eport, params: [{"lr", nil}]}] = route_set
    assert eport == port(ObEdge)
    assert {:ok, 200, []} = UAC.bye(dialog)

    # Through a first hop without outbound support
    assert {:ok, 439, []} =
             UAC.register(ObUA1, "sip:reg@caracola", [
               :contact,
               reg_id: 1,
               route: route(TestProxy)
             ])
  end
end
