defmodule Caracola.AuthTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Digest, UAC}
  alias Caracola.Test.{Client, Location, Server}
  alias Caracola.Test.Proxy, as: TestProxy

  import Caracola.Test.Helpers

  # Adapted from NkSIP's t13_auth. Server requires digest authentication in
  # realm "server"; the user "client" has the password "1234".

  @server_auth [auth: [realm: "server"], passwords: %{"client" => "1234"}]

  defp start_auth(server, client_sip \\ []) do
    port = start_service(Server, server)
    start_service(Client, sip: client_sip)
    "sip:127.0.0.1:#{port}"
  end

  test "digest" do
    uri = start_auth(@server_auth)

    assert {:ok, 401, [{"www-authenticate", [challenge]}]} =
             UAC.options(Client, uri, get_meta: ["www-authenticate"])

    assert {:ok, %{realm: "server", qop: [:auth]}} = Digest.parse(challenge)

    assert {:ok, 200, [cseq_num: cseq]} =
             UAC.options(Client, uri, password: "1234", get_meta: [:cseq_num])

    assert {:ok, 403, [cseq_num: cseq2]} =
             UAC.options(Client, uri, password: "12345", get_meta: [:cseq_num])

    # The challenged request is sent again with the next CSeq
    assert is_integer(cseq) and is_integer(cseq2)

    assert {:ok, 200, []} = UAC.options(Client, uri, password: {"server", "1234"})
    # No password for the realm
    assert {:ok, 401, []} = UAC.options(Client, uri, password: {"other", "1234"})

    ha1 = Digest.ha1("client", "1234", "server")
    assert {:ok, 200, []} = UAC.options(Client, uri, password: {:ha1, ha1})

    assert {:async, _} =
             UAC.options(Client, uri, [:async, password: "1234", callback: callback()])

    assert_receive {:callback, {:resp, 200, _}}
  end

  test "SHA-256 and SHA-512-256 (RFC 8760)" do
    uri = start_auth(@server_auth ++ [sip: [digest_algorithms: [:md5, :sha512_256, :sha256]]])

    # One challenge for each algorithm, the strongest first
    assert {:ok, 401, [{"www-authenticate", challenges}]} =
             UAC.options(Client, uri, get_meta: ["www-authenticate"])

    algorithms = for c <- challenges, {:ok, %{algorithm: a}} = Digest.parse(c), do: a
    assert algorithms == [:sha512_256, :sha256, :md5]

    # The strongest one is answered
    assert {:ok, 200, []} =
             UAC.options(Client, uri, [:get_request, password: "1234", callback: callback()])

    # The request sent again with credentials
    assert_receive {:callback, {:req, %{headers: headers}}}
    refute List.keymember?(headers, "authorization", 0)
    assert_receive {:callback, {:req, req}}
    assert [auth] = Caracola.Message.header(req, "authorization")
    assert {:ok, %{algorithm: :sha512_256}} = Digest.parse(auth)

    # With an MD5 HA1, the MD5 challenge is answered
    ha1 = Digest.ha1("client", "1234", "server")
    assert {:ok, 200, []} = UAC.options(Client, uri, password: {:ha1, ha1})
  end

  test "only SHA-256 accepted" do
    uri = start_auth(@server_auth ++ [sip: [digest_algorithms: [:sha256]]])
    assert {:ok, 200, []} = UAC.options(Client, uri, password: "1234")

    # MD5 credentials (for a challenge the server did not send) are rejected
    md5 =
      Digest.authorization(Digest.challenge("server", "n1"),
        method: :options,
        uri: uri,
        user: "client",
        password: "1234"
      )

    {:ok, md5} = md5
    assert {:ok, code, []} = UAC.options(Client, uri, [{:add, "authorization", md5}])
    assert code in [401, 403]

    # An MD5 HA1 cannot answer a SHA-256 challenge
    ha1 = Digest.ha1("client", "1234", "server")
    assert {:ok, 401, []} = UAC.options(Client, uri, password: {:ha1, ha1})
    assert {:ok, 200, []} = UAC.options(Client, uri, password: {:ha1, :sha256, ha1_256()})
  end

  defp ha1_256, do: Digest.ha1("client", "1234", "server", :sha256)

  test "challenged invites: dialogs and cancel" do
    uri = start_auth(@server_auth)
    opts = [password: "1234", from: "sip:client@127.0.0.1"]

    # A From without tag gets one, so the dialog is created
    assert {:ok, 200, [dialog: {:dialog, _, _, _} = dialog]} =
             UAC.invite(Client, uri, [:auto_2xx_ack, {:add, "x-op", "ok"} | opts])

    assert {:ok, 200, []} = UAC.bye(dialog, password: "1234")

    # The handle of the first request cancels the one sent with credentials
    assert {:async, handle} =
             UAC.invite(
               Client,
               uri,
               [:async, {:add, "x-op", "ok"}, {:add, "x-prov", "true"}, {:add, "x-sleep", "2000"}] ++
                 [callback: callback()] ++ opts
             )

    assert_receive {:callback, {:resp, 180, _}}
    assert :ok = UAC.cancel(handle)
    assert_receive {:callback, {:resp, 487, _}}
  end

  test "passwords in the configuration" do
    uri = start_auth(@server_auth, password: ["bad", {"server", "1234"}])

    # The password of the realm is preferred
    assert {:ok, 200, []} = UAC.options(Client, uri)
    assert {:ok, 200, []} = UAC.options(Client, uri, password: "other")
    assert {:ok, 403, []} = UAC.options(Client, uri, password: {"server", "bad"})
  end

  test "authorized dialogs" do
    uri = start_auth(auth: [realm: "server", dialog: true], passwords: %{"client" => "1234"})

    assert {:ok, 401, []} = UAC.invite(Client, uri, [{:add, "x-op", "ok"}])

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Client, uri, [{:add, "x-op", "ok"}, password: "1234"])

    # The ACK goes with the same credentials
    assert UAC.ack(dia) == :ok
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}

    # In-dialog requests from the same origin are authorized
    assert {:ok, 200, []} = UAC.options(dia)

    [dib] = Dialog.list(Server, elem(dia, 2))
    assert [{:udp, {127, 0, 0, 1}, port}] = Dialog.authorized(dib)
    assert port == port(Client)
    assert [{:udp, {127, 0, 0, 1}, port}] = Dialog.authorized(dia)
    assert port == port(Server)

    assert Dialog.clear_authorized(dib) == :ok
    assert Dialog.authorized(dib) == []
    assert {:ok, 401, []} = UAC.options(dia)
    assert {:ok, 200, []} = UAC.options(dia, password: "1234")
    assert {:ok, 200, []} = UAC.options(dia)

    assert {:ok, 200, []} = UAC.bye(dia)
    assert_receive {Server, {:bye, _}}
  end

  test "without dialog authorization" do
    uri = start_auth(@server_auth)

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Client, uri, [{:add, "x-op", "ok"}, password: "1234"])

    assert UAC.ack(dia) == :ok
    assert {:ok, 401, []} = UAC.options(dia)
    assert {:ok, 200, []} = UAC.options(dia, password: "1234")

    # A re-INVITE answered after the challenge
    assert {:ok, 401, []} = UAC.invite(dia, [{:add, "x-op", "ok"}])
    assert {:ok, 200, [dialog: ^dia]} = UAC.invite(dia, [{:add, "x-op", "ok"}, password: "1234"])
    assert UAC.ack(dia) == :ok
    assert {:ok, 200, []} = UAC.bye(dia, password: "1234")
  end

  test "proxy" do
    start_auth(@server_auth)

    start_service(TestProxy,
      proxy: [],
      auth: [realm: "proxy", proxy: true],
      passwords: %{"client" => "4321"}
    )

    Location.put(TestProxy, "server", "<sip:server@127.0.0.1:#{port(Server)}>")
    on_exit(fn -> Location.delete(TestProxy, "server") end)
    opts = [{:add, "x-op", "ok"}, route: route(TestProxy)]

    assert {:ok, 407, [{"proxy-authenticate", [challenge]}]} =
             UAC.invite(Client, "sip:server@nksip", [get_meta: ["proxy-authenticate"]] ++ opts)

    assert {:ok, %{realm: "proxy"}} = Digest.parse(challenge)

    # The proxy accepts, but not the server
    assert {:ok, 403, []} =
             UAC.invite(
               Client,
               "sip:server@nksip",
               [password: [{"proxy", "4321"}, "bad"]] ++ opts
             )

    # Proxy and server accept
    passwords = [{"proxy", "4321"}, {"server", "1234"}]

    assert {:ok, 200, [dialog: dia]} =
             UAC.invite(Client, "sip:server@nksip", [password: passwords] ++ opts)

    assert UAC.ack(dia) == :ok
    assert_receive {Server, {:dialog, {:invite_status, :confirmed}}}
    assert {:ok, 200, []} = UAC.bye(dia, password: passwords)
  end
end
