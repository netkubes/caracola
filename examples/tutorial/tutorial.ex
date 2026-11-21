defmodule Caracola.Tutorial do
  @moduledoc """
  Code of the [tutorial](03-tutorial.md). `launch/0` runs all its steps.
  """

  alias Caracola.{Dialog, Registrar, SDP, UAC}
  alias Caracola.Tutorial.{Client1, Client2, Server}

  @doc """
  Starts the server and the two clients. TLS uses certificates generated
  for the tutorial (see `tls_config/0`).
  """
  @spec start() :: :ok
  def start do
    {server_tls, client_tls} = tls_config()
    tls = [tls: server_tls, tls_client: client_tls]

    for service <- [Server, Client1, Client2] do
      {:ok, _} = service.start_link(sip: tls)
      :ok = Caracola.wait_ready(service)
    end

    :ok
  end


  @doc "Stops the services."
  @spec stop() :: :ok
  def stop do
    for service <- [Client2, Client1, Server], Process.whereis(service), do: service.stop()
    :ok
  end

  @doc """
  A certificate authority and a certificate signed by it, for the TLS
  listeners (`:tls`), and the options for the clients to trust it
  (`:tls_client`). Only for testing!
  """
  @spec tls_config() :: {keyword(), keyword()}
  def tls_config do
    opts = [key: {:rsa, 2048, 65_537}, digest: :sha256]
    chain = %{root: opts, intermediates: [], peer: opts}

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

    {server, Keyword.take(client, [:cacerts])}
  end

  @doc "Runs all the steps of the tutorial, checking the results."
  @spec launch() :: :ok
  def launch do
    :ok = start()
    Registrar.clear(Server)

    # OPTIONS from client2 to client1, and from client1 to the server
    {:ok, 200, []} = UAC.options(Client2, "sip:127.0.0.1:5070")

    {:ok, 407, [reason_phrase: "Proxy Authentication Required"]} =
      UAC.options(Client1, "sip:127.0.0.1", get_meta: [:reason_phrase])

    # With the password
    {:ok, 200, []} = UAC.options(Client1, "sip:127.0.0.1", password: "1234")
    {:ok, 200, []} = UAC.options(Client2, "<sip:127.0.0.1;transport=tls>", password: "1234")

    # Registrations
    {:ok, 200, [{"contact", [_contact]}]} =
      UAC.register(Client1, "sip:127.0.0.1", [:contact, password: "1234", get_meta: ["contact"]])

    {:ok, 200, []} = UAC.register(Client2, "sips:127.0.0.1", [:contact, password: "1234"])

    {:ok, 200, [contacts: [%Caracola.URI{scheme: :sips, user: "client2"}]]} =
      UAC.register(Client2, "sips:127.0.0.1", password: "1234", get_meta: [:contacts])

    # Requests from the registered contacts need no password
    {:ok, 200, []} = UAC.options(Client1, "sip:127.0.0.1")
    {:ok, 200, []} = UAC.options(Client2, "sips:127.0.0.1")

    # Through the proxy: TLS from client1 is not a registered origin
    {:ok, 407, []} = UAC.options(Client1, "sips:client2@example.com", route: "<sip:127.0.0.1;lr>")

    {:ok, 200, [{"x-caracola-id", ["client2"]}]} =
      UAC.options(Client1, "sips:client2@example.com",
        route: "<sip:127.0.0.1;lr>",
        password: "1234",
        get_meta: ["x-caracola-id"]
      )

    # A call from client2 to client1, through the proxy
    {:ok, 488, []} = UAC.invite(Client2, "sip:client1@example.com", route: "<sips:127.0.0.1;lr>")

    {:ok, 200, [dialog: dialog]} =
      UAC.invite(Client2, "sip:client1@example.com", [
        :auto_2xx_ack,
        route: "<sips:127.0.0.1;lr>",
        body: SDP.new("127.0.0.1", [{"audio", 1080, [{:rtpmap, 0, "PCMU/8000"}]}])
      ])

    {:ok, %Dialog{invite: %{status: :confirmed}}} = Dialog.get(dialog)

    # The dialog is in both clients (the proxy only stays in its path)
    {:dialog, _, call_id, _} = dialog
    for service <- [Client1, Client2], do: [_] = Dialog.list(service, call_id)

    {:ok, 200, []} = UAC.bye(dialog)
    stop()
  end
end
