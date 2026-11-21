defmodule Caracola.ForkTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.Test.{Client, Location, Server, Server2}
  alias Caracola.Test.Proxy, as: TestProxy
  alias Caracola.UAC

  import Caracola.Test.Helpers

  # Adapted from NkSIP's t11_fork. The proxy forks to Server and Server2,
  # which reply depending on the user of the Request-URI (`sleep` parameter
  # to wait before replying)

  setup do
    start()
    start_service(Server2)
    start_service(TestProxy, proxy: [])
    on_exit(fn -> Location.delete(TestProxy, "fork") end)
    %{route: route(TestProxy)}
  end

  defp uri(service, op, params \\ ""), do: "<sip:#{op}@127.0.0.1:#{port(service)}#{params}>"

  defp fork(uri_set, opts) do
    Location.put(TestProxy, "fork", uri_set)
    UAC.invite(Client, "sip:fork@nksip", [route: route(TestProxy)] ++ opts)
  end

  test "parallel and serial" do
    assert {:ok, 200, [dialog: dia]} = fork([uri(Server, "busy"), uri(Server2, "ok")], [])
    assert_receive {Server, {:route, :invite}}
    assert_receive {Server2, {:route, :invite}}
    assert UAC.ack(dia) == :ok
    assert {:ok, 200, []} = UAC.bye(dia)
    assert_receive {Server2, {:bye, _}}

    # Serial
    assert {:ok, 200, [dialog: dia]} = fork([[uri(Server, "busy")], [uri(Server2, "ok")]], [])
    assert UAC.ack(dia) == :ok
    assert {:ok, 200, []} = UAC.bye(dia)

    # The best response: 404 is better than 486
    assert {:ok, 404, []} = fork([uri(Server, "busy"), uri(Server2, "notfound")], [])

    # Nobody answers
    assert {:ok, 480, []} = fork([], [])
  end

  test "6xx cancels the other branches" do
    uri_set = [uri(Server, "decline", ";sleep=100"), uri(Server2, "ok", ";sleep=2000")]
    assert {:ok, 603, []} = fork(uri_set, [{:add, "x-prov", "true"}])
    assert_receive {Server2, {:cancel, _}}
  end

  test "2xx from several branches" do
    # Both answer at once, so the second 200 is sent before the CANCEL
    # arrives. The first one is the response, the second one creates a
    # dialog that the UAC ends at once.
    assert {:ok, 200, [dialog: dia]} = fork([uri(Server, "ok"), uri(Server2, "ok")], [])
    assert_receive {other, {:route, :ack}}
    assert_receive {^other, {:bye, _}}
    assert_receive {^other, {:dialog, {:invite_status, {:stop, :caller_bye}}}}
    assert UAC.ack(dia) == :ok
    assert {:ok, 200, []} = UAC.bye(dia)
    [first] = [Server, Server2] -- [other]
    assert_receive {^first, {:bye, _}}
  end

  test "redirects" do
    redirect = {:add, "x-redirect", uri(Server2, "ok")}
    assert {:ok, 302, []} = fork([uri(Server, "redirect")], [redirect])

    # Following redirects
    Location.put(TestProxy, "fork", [uri(Server, "redirect")])
    opts = Base.encode64(:erlang.term_to_binary([:follow_redirects]))

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Client, "sip:fork@nksip", [
               redirect,
               {:add, "x-proxy-opts", opts},
               route: route(TestProxy)
             ])

    assert_receive {Server2, {:route, :invite}}
    assert UAC.ack(dia) == :ok
    assert {:ok, 200, []} = UAC.bye(dia)
  end

  test "cancel" do
    Location.put(TestProxy, "fork", [
      uri(Server, "ok", ";sleep=2000"),
      uri(Server2, "ok", ";sleep=2000")
    ])

    assert {:async, handle} =
             UAC.invite(Client, "sip:fork@nksip", [
               {:add, "x-prov", "true"},
               :async,
               route: route(TestProxy),
               callback: callback()
             ])

    assert_receive {:callback, {:resp, 180, _}}
    assert UAC.cancel(handle) == :ok
    assert_receive {:callback, {:resp, 487, _}}
    assert_receive {Server, {:cancel, _}}
    assert_receive {Server2, {:cancel, _}}
  end
end
