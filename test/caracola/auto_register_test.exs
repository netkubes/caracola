defmodule Caracola.AutoRegisterTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Registrar, UACAutoRegister}
  alias Caracola.Test.AutoUA
  alias Caracola.Test.Registrar, as: TestRegistrar

  import Caracola.Test.Helpers

  # Ported from the auto/0 test of NkSIP's t04_uas

  setup ctx do
    on_exit(fn -> Registrar.clear(TestRegistrar) end)
    service_route = ctx[:service_route] || []
    rport = start_service(TestRegistrar, registrar: [min_time: 1, service_route: service_route])
    start_service(AutoUA)
    %{uri: "<sip:127.0.0.1:#{rport};transport=tcp>"}
  end

  test "registrations and pings", %{uri: uri} do
    assert UACAutoRegister.start_ping(Other, :p, "sip:a") == {:error, :service_not_started}
    assert UACAutoRegister.start_ping(AutoUA, :p, "sip::a") == {:error, :invalid_uri}

    assert UACAutoRegister.start_register(AutoUA, :r, "sip:a", get_meta: []) ==
             {:error, :meta_not_allowed}

    assert UACAutoRegister.start_ping(AutoUA, :ping1, uri, expires: 5) == {:ok, true}
    assert UACAutoRegister.start_register(AutoUA, :reg1, uri, expires: 3) == {:ok, true}
    assert_receive {:ping, :ping1, true}
    assert_receive {:reg, :reg1, true}

    assert [{:ping1, true, _}] = UACAutoRegister.get_pings(AutoUA)
    assert [{:reg1, true, _}] = UACAutoRegister.get_registers(AutoUA)
    assert [_] = Registrar.find(TestRegistrar, :sip, "auto", "caracola")

    # The registration (of 3 seconds) is refreshed
    Process.sleep(4000)
    assert [_] = Registrar.find(TestRegistrar, :sip, "auto", "caracola")

    # Failures
    bad = "<sip:127.0.0.1:1;transport=tcp>"
    assert UACAutoRegister.start_ping(AutoUA, :ping2, bad, expires: 1) == {:ok, false}
    assert UACAutoRegister.start_register(AutoUA, :reg2, bad, expires: 1) == {:ok, false}
    assert_receive {:ping, :ping2, false}
    assert_receive {:reg, :reg2, false}

    assert [{:ping1, true, _}, {:ping2, false, _}] =
             Enum.sort(UACAutoRegister.get_pings(AutoUA))

    assert [{:reg1, true, _}, {:reg2, false, _}] =
             Enum.sort(UACAutoRegister.get_registers(AutoUA))

    assert UACAutoRegister.stop_ping(AutoUA, :ping2) == :ok
    assert UACAutoRegister.stop_register(AutoUA, :reg2) == :ok
    assert UACAutoRegister.stop_ping(AutoUA, :ping2) == :not_found

    # Stopping a registration unregisters it
    assert UACAutoRegister.stop_register(AutoUA, :reg1) == :ok
    eventually(fn -> Registrar.find(TestRegistrar, :sip, "auto", "caracola") == [] end)
    assert UACAutoRegister.stop_ping(AutoUA, :ping1) == :ok
    assert UACAutoRegister.get_pings(AutoUA) == []
    assert UACAutoRegister.get_registers(AutoUA) == []
  end

  test "unregister when the service stops", %{uri: uri} do
    assert UACAutoRegister.start_register(AutoUA, :reg1, uri) == {:ok, true}
    assert [_] = Registrar.find(TestRegistrar, :sip, "auto", "caracola")
    stop_supervised!(AutoUA)
    assert Registrar.find(TestRegistrar, :sip, "auto", "caracola") == []
  end

  @tag service_route: ["<sip:orig@scscf.example.com;lr>", "<sip:pcscf.example.com;lr>"]
  test "service route", %{uri: uri} do
    assert UACAutoRegister.service_route(AutoUA, :reg1) == []
    assert UACAutoRegister.start_register(AutoUA, :reg1, uri, expires: 5) == {:ok, true}

    assert UACAutoRegister.service_route(AutoUA, :reg1) ==
             ["<sip:orig@scscf.example.com;lr>", "<sip:pcscf.example.com;lr>"]

    # Returned in the responses of the registrar
    assert {:ok, 200, [{"service-route", [_, _]}]} =
             Caracola.UAC.register(AutoUA, uri, [:contact, get_meta: ["service-route"]])

    assert :ok = UACAutoRegister.stop_register(AutoUA, :reg1)
  end
end
