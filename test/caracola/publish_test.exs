defmodule Caracola.PublishTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{EventCompositor, UAC}
  alias Caracola.EventCompositor.Publication
  alias Caracola.Test.{Client, Compositor}

  import Caracola.Test.Helpers

  # Ported from NkSIP's t16_publish

  setup do
    on_exit(fn -> EventCompositor.clear(Compositor) end)
    port = start_service(Compositor)
    start_service(Client)
    %{uri: "sip:user1@127.0.0.1:#{port}", aor: {:sip, "user1", "127.0.0.1"}}
  end

  test "basic", %{uri: uri, aor: aor} do
    opts = [event: "nkpublish"]

    assert {:ok, 200, [sip_etag: tag1, expires: 5]} =
             UAC.publish(Client, uri, opts ++ [expires: 5, body: "data1"])

    assert {:ok, %Publication{data: "data1"}} = EventCompositor.find(Compositor, aor, tag1)

    # Unknown tag
    assert {:ok, 412, []} = UAC.publish(Client, uri, opts ++ [sip_if_match: "other"])

    # Removal
    assert {:ok, 200, [sip_etag: ^tag1, expires: 0]} =
             UAC.publish(Client, uri, opts ++ [expires: 0, sip_if_match: tag1])

    assert EventCompositor.find(Compositor, aor, tag1) == :not_found

    assert {:ok, 200, [sip_etag: tag2, expires: 60]} =
             UAC.publish(Client, uri, opts ++ [body: "data2"])

    assert {:ok, %Publication{data: "data2"}} = EventCompositor.find(Compositor, aor, tag2)

    # Modification
    assert {:ok, 200, [sip_etag: ^tag2, expires: 1]} =
             UAC.publish(Client, uri, opts ++ [expires: 1, sip_if_match: tag2, body: "data3"])

    assert {:ok, %Publication{data: "data3"}} = EventCompositor.find(Compositor, aor, tag2)

    # Refresh without body keeps the data
    assert {:ok, 200, [sip_etag: ^tag2, expires: 30]} =
             UAC.publish(Client, uri, opts ++ [expires: 30, sip_if_match: tag2])

    assert {:ok, %Publication{data: "data3"}} = EventCompositor.find(Compositor, aor, tag2)
  end

  test "errors", %{uri: uri} do
    assert {:ok, 400, []} = UAC.publish(Client, uri, event: "nkpublish")
    assert {:ok, 489, []} = UAC.publish(Client, uri, event: "other", body: "a")
    assert {:ok, 405, []} = UAC.publish(Client, "sip:127.0.0.1:#{port(Client)}", event: "a")
  end
end
