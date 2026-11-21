defmodule Caracola.AssertedIdentityTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{AssertedIdentity, Message, UAC}
  alias Caracola.Test.{AiProxy, AiUAS, Client}

  import Caracola.Test.Helpers

  doctest AssertedIdentity

  @pai {:add, "p-asserted-identity", "<sip:forged@example.com>"}

  defp proxy_opts(opts), do: {:add, "x-proxy-opts", Base.encode64(:erlang.term_to_binary(opts))}

  test "identities from untrusted nodes are removed" do
    start_service(Client)
    port = start_service(AiUAS, asserted_identity: [trusted: ["10.0.0.0/8"]])
    uri = "sip:127.0.0.1:#{port}"

    assert {:ok, 200, [dialog: d1]} = UAC.invite(Client, uri, [:auto_2xx_ack, @pai])
    assert_receive {:identity, [], []}
    UAC.bye(d1)
  end

  test "identities from trusted nodes are kept" do
    start_service(Client)
    port = start_service(AiUAS, asserted_identity: [trusted: ["127.0.0.0/8"]])

    assert {:ok, 200, [dialog: d1]} =
             UAC.invite(Client, "sip:127.0.0.1:#{port}", [:auto_2xx_ack, @pai])

    assert_receive {:identity, ["forged@example.com"], []}
    UAC.bye(d1)
  end

  test "a proxy asserts the identity" do
    start_service(Client)
    uas_port = start_service(AiUAS, asserted_identity: [trusted: ["127.0.0.1"]])
    start_service(AiProxy)

    # The client is not trusted: its asserted identity is removed, and the
    # proxy asserts another one, removing the preferred one
    asserted = ["<sip:alice@example.com>", "<tel:+15551234>"]

    opts = [
      :auto_2xx_ack,
      @pai,
      {:add, "p-preferred-identity", "<sip:alice@example.com>"},
      proxy_opts(AssertedIdentity.assert_opts(asserted)),
      route: route(AiProxy)
    ]

    assert {:ok, 200, [dialog: d1]} =
             UAC.invite(Client, "sip:ok@127.0.0.1:#{uas_port}", opts)

    assert_receive {:identity, ["alice@example.com", "@+15551234"], []}
    UAC.bye(d1)
  end

  test "privacy and forwarding outside the trust domain" do
    {:ok, req} = Message.update_header(%Message{}, :add, "privacy", "id")
    assert AssertedIdentity.privacy(req) == [:id]
    assert AssertedIdentity.forward_opts(req, false) == [{:remove, "p-asserted-identity"}]
    assert AssertedIdentity.forward_opts(req, true) == []
    assert AssertedIdentity.forward_opts(%Message{}, false) == []

    {:ok, req} = Message.update_header(%Message{}, :add, "privacy", "header;user;foo")
    assert AssertedIdentity.privacy(req) == [:header, :user, "foo"]
  end

  test "trusted addresses" do
    start_service(AiUAS,
      asserted_identity: [trusted: ["10.0.0.0/8", "192.0.2.1", "2001:db8::/32"]]
    )

    assert AssertedIdentity.trusted?(AiUAS, {10, 1, 2, 3})
    refute AssertedIdentity.trusted?(AiUAS, {11, 1, 2, 3})
    assert AssertedIdentity.trusted?(AiUAS, {192, 0, 2, 1})
    refute AssertedIdentity.trusted?(AiUAS, {192, 0, 2, 2})
    assert AssertedIdentity.trusted?(AiUAS, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    refute AssertedIdentity.trusted?(AiUAS, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
    refute AssertedIdentity.trusted?(AiUAS, nil)
  end

  test "invalid trusted addresses" do
    assert {:error, _} =
             start_supervised({AiUAS, [asserted_identity: [trusted: ["10.0.0.0/33"]]]})
  end
end
