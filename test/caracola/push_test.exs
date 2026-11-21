defmodule Caracola.PushTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Message, Push, Registrar, UAC}
  alias Caracola.Test.{Client, PushProxy, Server}

  import Caracola.Test.Helpers

  doctest Push

  # The client registers the server (the "phone", answering INVITEs to the
  # user "ok") as client@caracola, through the proxy
  setup do
    start_service(Client)
    server = start_service(Server)
    on_exit(fn -> Registrar.clear(PushProxy) end)
    {:ok, server: server}
  end

  defp start_proxy(config \\ []) do
    config = Keyword.update(config, :push, [timeout: 1000], &Keyword.put_new(&1, :timeout, 1000))
    start_service(PushProxy, config)
    Registrar.clear(PushProxy)
    "sip:127.0.0.1:#{port(PushProxy)}"
  end

  defp contact(server, params),
    do: "<sip:ok@127.0.0.1:#{server}#{params}>"

  defp push_contact(server, prid \\ "tok1"),
    do: contact(server, ";pn-provider=apns;pn-prid=#{prid};pn-param=team.app")

  defp register(proxy, contact) do
    UAC.register(Client, proxy, contact: contact, get_meta: ["feature-caps"])
  end

  defp invite(opts \\ []),
    do:
      UAC.invite(Client, "sip:client@caracola", [:auto_2xx_ack, route: route(PushProxy)] ++ opts)

  test "devices are woken up and get the request after registering", %{server: server} do
    proxy = start_proxy()

    assert {:ok, 200, [{"feature-caps", [caps]}]} =
             register(proxy, push_contact(server))

    assert caps =~ ~s(*;+sip.pns="apns";+sip.pnspurr=")

    task = Task.async(fn -> invite() end)

    assert_receive {:push, %{provider: "apns", prid: "tok1", param: "team.app", purr: purr}}
    assert caps =~ purr
    refute Task.yield(task, 200)

    # The device registers again (from another address, the same token)
    assert {:ok, 200, _} = register(proxy, push_contact(server))
    assert {:ok, 200, [dialog: dialog]} = Task.await(task)
    assert {:ok, 200, []} = UAC.bye(dialog)
    assert length(Registrar.find(PushProxy, :sip, "client", "caracola")) == 1
  end

  test "without a new registration, the request fails", %{server: server} do
    proxy = start_proxy(push: [timeout: 200])
    assert {:ok, 200, _} = register(proxy, push_contact(server))
    assert {:ok, 480, []} = invite()
    assert_receive {:push, _}
  end

  test "failed pushes are not waited for", %{server: server} do
    proxy = start_proxy(push_result: {:error, :unavailable})
    assert {:ok, 200, _} = register(proxy, push_contact(server))
    assert {:ok, 480, []} = invite()
  end

  test "contacts without push are used at once", %{server: server} do
    proxy = start_proxy(push: [timeout: 300])
    assert {:ok, 200, [{"feature-caps", []}]} = register(proxy, contact(server, ""))
    assert {:ok, 200, [dialog: dialog]} = invite()
    UAC.bye(dialog)
    refute_received {:push, _}

    # With a push contact too, the other one gets it after the wait
    assert {:ok, 200, _} = register(proxy, push_contact(server, "tok2"))
    assert {:ok, 200, [dialog: dialog]} = invite()
    UAC.bye(dialog)
    assert_received {:push, %{prid: "tok2"}}
  end

  test "requests can be cancelled while waiting", %{server: server} do
    proxy = start_proxy(push: [timeout: 500])
    assert {:ok, 200, _} = register(proxy, push_contact(server))

    assert {:async, handle} = invite([:async, callback: callback()])
    assert_receive {:push, _}
    :ok = UAC.cancel(handle)
    assert_receive {:callback, {:resp, 487, _}}, 1000
  end

  test "unsupported providers are rejected", %{server: server} do
    proxy = start_proxy(push: [providers: ["fcm"]])
    assert {:ok, 555, _} = register(proxy, push_contact(server))
  end

  test "routing a request that is gone" do
    req = %Message{class: {:req, :invite}, service: Server, call_id: "none", id: "x"}
    assert Caracola.route(req, :proxy) == {:error, :invalid_request}
  end
end
