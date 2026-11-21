defmodule Caracola.RegistrarTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Message, Registrar, UAC, URI}
  alias Caracola.Registrar.Contact
  alias Caracola.Test.{Client, Location, Server}
  alias Caracola.Test.Proxy, as: TestProxy
  alias Caracola.Test.Registrar, as: TestRegistrar
  alias Caracola.Transport.Port

  import Caracola.Test.Helpers

  # Ported and adapted from NkSIP's t08_register and t18_path. The client
  # registers as sip:client@caracola.

  setup do
    on_exit(fn -> Registrar.clear(TestRegistrar) end)
    :ok
  end

  defp start_registrar(config \\ []) do
    rport = start_service(TestRegistrar, [registrar: [min_time: 60]] ++ config)
    start_service(Client)
    "sip:127.0.0.1:#{rport}"
  end

  defp find(scheme \\ :sip), do: Registrar.find(TestRegistrar, scheme, "client", "caracola")

  test "register" do
    uri = start_registrar()
    cport = port(Client)

    # Without registrar
    assert {:ok, 405, []} = UAC.register(Client, "sip:127.0.0.1:#{cport}")

    assert {:ok, 200, [{"contact", []}]} =
             UAC.register(Client, uri, [:unregister_all, get_meta: ["contact"]])

    assert find() == []

    assert {:async, _} =
             UAC.register(Client, uri, [:async, :contact, :get_request, callback: callback()])

    assert_receive {:callback, {:req, %Message{call_id: call_id, cseq: {cseq, _}}}}
    assert_receive {:callback, {:resp, 200, %Message{contacts: [contact]}}}

    assert [%URI{user: "client", domain: "127.0.0.1", port: ^cport} = found] = find()
    assert URI.get_ext_param(found, "expires") == {:ok, "3600"}
    assert found == contact

    # Old CSeq in the same Call-ID
    assert {:ok, 400, [reason_phrase: "Rejected Old CSeq"]} =
             UAC.register(Client, uri, [
               :contact,
               call_id: call_id,
               cseq_num: cseq,
               get_meta: [:reason_phrase]
             ])

    assert {:ok, 200, []} =
             UAC.register(Client, uri, [:contact, call_id: call_id, cseq_num: cseq + 1])

    assert {:ok, 400, []} =
             UAC.register(Client, uri, [:unregister_all, call_id: call_id, cseq_num: cseq + 1])

    # Expiration limits
    assert {:ok, 423, [{"min-expires", ["60"]}]} =
             UAC.register(Client, uri, [:contact, expires: 59, get_meta: ["min-expires"]])

    assert {:ok, 200, [contacts: [contact]]} =
             UAC.register(Client, uri, [:contact, expires: 86_401, get_meta: [:contacts]])

    assert URI.get_ext_param(contact, "expires") == {:ok, "86400"}

    assert {:ok, 200, [contacts: [contact]]} =
             UAC.register(Client, uri, [:contact, expires: 60, get_meta: [:contacts]])

    assert URI.get_ext_param(contact, "expires") == {:ok, "60"}

    assert [%Contact{q: 1.0, expire: expire, origin: {:udp, {127, 0, 0, 1}, ^cport}}] =
             Registrar.get_info(TestRegistrar, {:sip, "client", "caracola"})

    assert_in_delta expire, System.os_time(:second) + 60, 1

    # Requests from the registered address
    {:ok, [from]} = URI.parse("<sip:client@caracola>")
    port = %Port{transport: :udp, remote_ip: {127, 0, 0, 1}, remote_port: cport}
    req = %Message{class: {:req, :options}, service: TestRegistrar, from: from, port: port}
    assert Registrar.registered?(req)
    refute Registrar.registered?(%{req | port: %{port | remote_port: cport + 1}})

    assert Registrar.delete(TestRegistrar, :sip, "client", "caracola") == :ok
    assert Registrar.delete(TestRegistrar, :sip, "client", "caracola") == :not_found
  end

  test "several contacts" do
    uri = start_registrar()
    cport = port(Client)
    opts = [:contact, expires: 300]

    assert {:ok, 200, []} = UAC.register(Client, uri, opts)
    assert {:ok, 200, []} = UAC.register(Client, "<#{uri};transport=tcp>", opts)
    assert {:ok, 200, []} = UAC.register(Client, uri, contact: "tel:123456", expires: 300)

    assert {:ok, 200, [contacts: contacts]} = UAC.register(Client, uri, get_meta: [:contacts])

    assert Enum.sort([
             "<sip:client@127.0.0.1:#{cport}>;expires=300",
             "<sip:client@127.0.0.1:#{cport};transport=tcp>;expires=300",
             "<tel:123456>;expires=300"
           ]) == contacts |> Enum.map(&to_string/1) |> Enum.sort()

    # Another AOR, with sips
    sips = [from: "<sips:client@caracola>", expires: 300]
    contact = "<sips:client@127.0.0.1:5071>"
    assert {:ok, 200, []} = UAC.register(Client, uri, [contact: contact] ++ sips)
    assert [%URI{scheme: :sips, port: 5071}] = find(:sips)
    assert {:ok, 200, []} = UAC.register(Client, uri, [contact: "#{contact};expires=0"] ++ sips)
    assert find(:sips) == []

    # Groups by q, the highest first
    assert {:ok, 200, []} = UAC.register(Client, uri, [:unregister_all])
    assert {:ok, 200, []} = UAC.register(Client, uri, [:contact])

    assert {:ok, 200, []} =
             UAC.register(Client, uri, contact: "<sip:bbb>;q=2.1;expires=180, <sips:ccc>;q=3")

    assert {:ok, 200, []} =
             UAC.register(Client, uri, contact: "<sip:ddd:444;transport=tcp>;q=2.1")

    assert [
             [%URI{scheme: :sips, domain: "ccc"}],
             [%URI{domain: "ddd", port: 444}, %URI{domain: "bbb"} = bbb],
             [%URI{user: "client", port: ^cport}]
           ] = Registrar.qfind(TestRegistrar, :sip, "client", "caracola")

    assert URI.get_ext_param(bbb, "expires") == {:ok, "180"}

    # The AOR cannot be a contact
    assert {:ok, 403, []} = UAC.register(Client, uri, contact: "<sip:client@caracola>")
  end

  test "path" do
    uri = start_registrar(proxy: [registrar: true])
    start_service(Server)
    start_service(TestProxy, proxy: [opts: [:path]])
    Location.put(TestProxy, "reg", uri)
    on_exit(fn -> Location.delete(TestProxy, "reg") end)

    # The client registers through the proxy, which adds a Path
    assert {:ok, 200, []} =
             UAC.register(Client, "sip:reg@caracola", [:contact, route: route(TestProxy)])

    assert [%URI{headers: [{"route", _}]}] = find()

    assert [%Contact{path: [%URI{user: "NkQ" <> _} = path]}] =
             Registrar.get_info(TestRegistrar, {:sip, "client", "caracola"})

    assert path.port == port(TestProxy)

    # Requests for the client go through the proxy
    assert {:ok, 200, [dialog: dialog]} =
             UAC.invite(Server, "sip:client@caracola", [
               {:add, "x-op", "ok"},
               route: route(TestRegistrar)
             ])

    assert_receive {Client, {:route, :invite}}
    assert_receive {TestProxy, {:route, :invite}}
    assert UAC.ack(dialog) == :ok
    assert {:ok, 200, []} = UAC.bye(dialog)
  end

  test "requests from registered contacts are authorized" do
    uri =
      start_registrar(
        auth: [realm: "reg", register: true],
        passwords: %{"client" => "1234"}
      )

    start_service(Server)

    assert {:ok, 401, []} = UAC.register(Client, uri, [:contact])
    assert {:ok, 200, []} = UAC.register(Client, uri, [:contact, password: "1234"])

    # From the registered contact
    assert {:ok, 200, []} = UAC.options(Client, uri)
    # From another address
    assert {:ok, 401, []} = UAC.options(Server, uri, from: "<sip:client@caracola>")
  end
end
