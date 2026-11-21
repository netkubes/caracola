defmodule Caracola.OverloadControlTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{OverloadControl, UAC}
  alias Caracola.Test.{Client, OcClient, OcServer}

  import Caracola.Test.Helpers

  @local {127, 0, 0, 1}

  setup do
    id = make_ref()
    pid = self()

    :telemetry.attach(
      id,
      [:caracola, :overload_control, :drop],
      fn _, _, meta, _ -> send(pid, {:drop, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    start_service(OcClient)
    start_service(Client)
    port = start_service(OcServer, overload_control: [validity: 300])
    OverloadControl.clear(OcServer)
    OverloadControl.clear(OcClient)
    %{uri: "sip:127.0.0.1:#{port}"}
  end

  defp options(service, uri) do
    case UAC.options(service, uri, get_meta: ["via"]) do
      {:ok, code, [{"via", [via | _]}]} -> {code, via}
      {:ok, code, _} -> {code, nil}
      {:error, :service_unavailable} -> {:not_sent, nil}
    end
  end

  test "servers tell clients supporting it the reduction", %{uri: uri} do
    {200, via} = options(OcClient, uri)
    assert via =~ ~s(;oc=0;oc-algo="loss";oc-validity=300;oc-seq=)

    # Clients without overload control get nothing
    {200, via} = options(Client, uri)
    refute via =~ "oc="
  end

  test "clients reduce the requests sent to overloaded servers", %{uri: uri} do
    :ok = OverloadControl.set_loss(OcServer, 100)
    assert OverloadControl.loss(OcServer) == 100

    {200, via} = options(OcClient, uri)
    assert via =~ ";oc=100;"
    assert OverloadControl.server_loss(OcClient, @local) == 100

    # Not sent
    assert_receive {OcServer, {:options, _}}
    assert {:not_sent, _} = options(OcClient, uri)
    refute_receive {OcServer, {:options, _}}, 100
    assert_receive {:drop, %{service: OcClient, ip: @local, loss: 100}}

    # Once the reduction expires, requests are sent again
    :ok = OverloadControl.set_loss(OcServer, 0)
    Process.sleep(300)
    assert OverloadControl.server_loss(OcClient, @local) == 0
    assert {200, via} = options(OcClient, uri)
    assert via =~ ";oc=0;"
  end

  test "partial reductions", %{uri: uri} do
    :ok = OverloadControl.set_loss(OcServer, 50, 5_000)
    {200, _} = options(OcClient, uri)
    codes = for _ <- 1..100, do: elem(options(OcClient, uri), 0)
    sent = Enum.count(codes, &(&1 == 200))
    assert sent in 25..75
  end

  test "requests in dialogs are not reduced", %{uri: uri} do
    assert {:ok, 200, [dialog: dialog]} =
             UAC.invite(OcClient, "sip:ok@" <> String.trim_leading(uri, "sip:"), [:auto_2xx_ack])

    :ok = OverloadControl.set_loss(OcServer, 100, 5_000)
    {200, _} = options(OcClient, uri)
    assert OverloadControl.server_loss(OcClient, @local) == 100
    assert {:ok, 200, []} = UAC.bye(dialog)
  end
end
