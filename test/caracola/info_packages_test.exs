defmodule Caracola.InfoPackagesTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, InfoPackages, Message, UAC}
  alias Caracola.Test.{InfoUA1, InfoUA2}

  import Caracola.Test.Helpers

  doctest InfoPackages

  setup do
    start_service(InfoUA1)
    start_service(InfoUA2)

    uri = "sip:ok@127.0.0.1:#{port(InfoUA2)}"

    assert {:ok, 200, [{:dialog, dialog}, {"recv-info", ["dtmf, foo"]}]} =
             UAC.invite(InfoUA1, uri, [:auto_2xx_ack, get_meta: ["recv-info"]])

    {:dialog, _, call_id, _} = dialog
    [remote] = Dialog.list(InfoUA2, call_id)
    on_exit(fn -> UAC.bye(dialog) end)
    %{dialog: dialog, remote: remote}
  end

  test "Recv-Info negotiation", %{dialog: dialog, remote: remote} do
    assert InfoPackages.remote_packages(dialog) == ["dtmf", "foo"]
    assert InfoPackages.remote_packages(remote) == ["dtmf"]
  end

  test "INFOs of a package", %{dialog: dialog, remote: remote} do
    body = "Signal=5\r\nDuration=160\r\n"

    assert {:ok, 200, []} =
             InfoPackages.send(dialog, "DTMF", body, content_type: "application/dtmf-relay")

    assert_receive {InfoUA2, {:info, req}}
    assert req.body == body
    assert InfoPackages.packages(req, "info-package") == ["dtmf"]
    assert Message.header(req, "content-disposition") == ["Info-Package"]

    # Not accepted by the remote side
    assert InfoPackages.send(dialog, "bar", "x") == {:error, :bad_info_package}
    assert InfoPackages.send(remote, "foo", "x") == {:error, :bad_info_package}

    # Sent anyway: 469 with the accepted packages
    assert {:ok, 469, [{"recv-info", ["dtmf"]}]} =
             UAC.info(remote, [{:add, "info-package", "foo"}, get_meta: ["recv-info"]])

    # Legacy INFO
    assert {:ok, 200, []} = UAC.info(remote, body: "x")
    assert_receive {InfoUA1, {:info, _}}
  end
end
