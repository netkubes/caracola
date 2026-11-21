defmodule Caracola.ProxyTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Call, Dialog, Message, UAC, URI}
  alias Caracola.Test.{Client, Location, Server}
  alias Caracola.Test.Proxy, as: TestProxy

  import Caracola.Test.Helpers

  # Ported and adapted from NkSIP's t10_proxy and the EUnit tests of
  # nksip_call_proxy. Users are located with Caracola.Test.Location instead
  # of a registrar.

  defp proxy_opts(opts), do: {:add, "x-proxy-opts", Base.encode64(:erlang.term_to_binary(opts))}

  test "uri sets" do
    a = %URI{domain: "a"}
    b = %URI{domain: "b"}
    c = %URI{domain: "c"}
    d = %URI{domain: "d"}
    e = %URI{domain: "e"}
    uri_set = &Caracola.Call.Proxy.uri_set/1

    assert uri_set.([]) == [[]]
    assert uri_set.(:a) == [[]]
    assert uri_set.([:a, :b]) == [[]]
    assert uri_set.("sip:a") == [[a]]
    assert uri_set.("other") == [[]]
    assert uri_set.(c) == [[c]]
    assert uri_set.([d]) == [[d]]
    assert uri_set.(["sip:a", "sip:b", c, "sip:d", "sip:e"]) == [[a, b, c, d, e]]
    assert uri_set.(["sip:a", ["sip:b", c], "sip:d", ["sip:e"]]) == [[a], [b, c], [d], [e]]
    assert uri_set.([["sip:a", "sip:b", c], "sip:d", "sip:e"]) == [[a, b, c], [d], [e]]
  end

  for mode <- [:stateful, :stateless] do
    describe "#{mode} proxy" do
      setup do
        sport = start()
        pport = start_service(TestProxy, proxy: [stateless: unquote(mode) == :stateless])
        Location.put(TestProxy, "server", "sip:server@127.0.0.1:#{sport}")
        on_exit(fn -> Location.delete(TestProxy, "server") end)
        %{route: route(TestProxy), proxy_port: pport, server_port: sport}
      end

      test "routing and errors", %{route: route, proxy_port: pport} do
        assert {:ok, 200, [call_id: call_id]} =
                 UAC.options(Client, "sip:server@nksip", route: route, get_meta: [:call_id])

        assert_receive {Server, {:options, req}}
        assert [_, _] = req.vias
        assert req.max_forwards == 69
        # The route pointing to the proxy has been removed
        assert req.routes == []
        assert req.ruri.domain == "127.0.0.1"

        # Only the stateful proxy keeps the transaction
        if unquote(mode) == :stateful,
          do: assert(Call.find(TestProxy, call_id) != nil),
          else: eventually(fn -> Call.find(TestProxy, call_id) == nil end)

        assert {:ok, 480, []} = UAC.options(Client, "sip:other@nksip", route: route)

        assert {:ok, 420, [{"unsupported", ["a,b,d"]}]} =
                 UAC.options(Client, "sip:server@nksip", [
                   {:add, "proxy-require", "a, b;c=1,d"},
                   route: route,
                   get_meta: ["unsupported"]
                 ])

        hops = {:replace, "max-forwards", 0}
        assert {:ok, 483, []} = UAC.message(Client, "sip:server@nksip", [hops, route: route])

        assert {:ok, 200, [reason_phrase: "Max Forwards"]} =
                 UAC.options(Client, "sip:server@nksip", [
                   hops,
                   route: route,
                   get_meta: [:reason_phrase]
                 ])

        # Without user, the proxy processes the request
        assert {:ok, 200, []} = UAC.options(Client, "sip:127.0.0.1:#{pport}")
        refute_received {Server, {:options, _}}
      end

      test "proxy options", %{route: route, server_port: sport} do
        opts = proxy_opts([{:insert, "x-nk", "proxy"}])

        assert {:ok, 200, []} =
                 UAC.options(Client, "sip:server@nksip", [
                   {:add, "x-nk", "client"},
                   opts,
                   route: route
                 ])

        assert_receive {Server, {:options, req}}
        assert Message.header(req, "x-nk") == ["proxy", "client"]

        # New routes
        routes = "<sip:127.0.0.1:#{sport};lr>, <sip:1.2.3.4;lr>"
        opts = proxy_opts(route: routes)
        assert {:ok, 200, []} = UAC.options(Client, "sip:server@nksip", [opts, route: route])
        assert_receive {Server, {:options, req}}
        assert to_string(URI.encode(req.routes)) == routes

        # Routes of the client after the proxy are removed
        opts = proxy_opts(route: [])

        assert {:ok, 200, []} =
                 UAC.options(Client, "sip:server@nksip", [opts, route: [route, "<sip:aaa;lr>"]])

        assert_receive {Server, {:options, %Message{routes: []}}}
      end

      test "invite", %{route: route} do
        assert {:ok, 486, []} =
                 UAC.invite(Client, "sip:server@nksip", [
                   {:add, "x-op", "busy"},
                   {:add, "x-prov", "true"},
                   route: route,
                   callback: callback()
                 ])

        assert_receive {:callback, {:resp, 180, _}}

        assert {:ok, 200, [dialog: dia]} =
                 UAC.invite(Client, "sip:server@nksip", [{:add, "x-op", "ok"}, route: route])

        # Without Record-Route, in-dialog requests go directly
        assert UAC.ack(dia) == :ok
        assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
        assert {:ok, 200, []} = UAC.options(dia)
        assert_receive {Server, {:options, %Message{vias: [_]}}}
        assert {:ok, 200, []} = UAC.bye(dia)

        # Cancelled
        assert {:async, handle} =
                 UAC.invite(Client, "sip:server@nksip", [
                   {:add, "x-op", "ok"},
                   {:add, "x-prov", "true"},
                   {:add, "x-sleep", "2000"},
                   :async,
                   route: route,
                   callback: callback()
                 ])

        assert_receive {:callback, {:resp, 180, _}}
        assert UAC.cancel(handle) == :ok
        assert_receive {:callback, {:resp, 487, _}}
        assert_receive {Server, {:cancel, _}}
      end

      test "record route", %{route: route} do
        opts = [{:add, "x-op", "ok"}, proxy_opts([:record_route]), route: route]
        assert {:ok, 200, [dialog: dia]} = UAC.invite(Client, "sip:server@nksip", opts)
        assert_receive {Server, {:route, :invite}}

        # The route set is the proxy
        assert [%URI{user: "NkQ" <> _, port: port}] = get(dia).route_set
        assert port == port(TestProxy)
        dib = remote(dia, Server)
        assert [%URI{user: "NkQ" <> _}] = get(dib).route_set

        # In-dialog requests go through the proxy in both directions
        assert UAC.ack(dia) == :ok
        assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
        assert {:ok, 200, []} = UAC.options(dia)
        assert_receive {Server, {:options, %Message{vias: [_, _]}}}
        assert {:ok, 200, []} = UAC.options(dib)
        assert_receive {Client, {:options, %Message{vias: [_, _]}}}
        assert {:ok, 200, []} = UAC.bye(dib)
        assert_receive {Client, {:bye, %Message{vias: [_, _]}}}
        assert_receive {Client, {:dialog, {:invite_status, {:stop, :callee_bye}}}}
      end
    end
  end

  defp get(dialog) do
    {:ok, dialog} = Dialog.get(dialog)
    dialog
  end

  defp remote({:dialog, _, call_id, _}, service) do
    [dialog] = Dialog.list(service, call_id)
    dialog
  end
end
