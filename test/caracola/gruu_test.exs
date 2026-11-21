defmodule Caracola.GruuTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Gruu, Registrar, UAC, URI}
  alias Caracola.Test.{GruuRegistrar, GruuUA1, GruuUA2}

  import Caracola.Test.Helpers

  # Ported from NkSIP's t15_gruu

  setup do
    on_exit(fn -> Registrar.clear(GruuRegistrar) end)
    for service <- [GruuRegistrar, GruuUA1, GruuUA2], do: start_service(service)
    %{registrar: "sip:127.0.0.1:#{port(GruuRegistrar)}"}
  end

  defp gruus(%URI{} = contact) do
    for param <- ["pub-gruu", "temp-gruu"] do
      {:ok, value} = URI.get_ext_param(contact, param)
      {:ok, uri} = URI.parse_one(String.trim(value, "\""))
      uri
    end
  end

  defp instance(service), do: ~s("#{service.get_config()[:sip][:instance_id]}")

  test "register", %{registrar: registrar} do
    assert {:ok, 200, [contacts: [c1]]} =
             UAC.register(GruuUA1, registrar, [:contact, get_meta: [:contacts]])

    assert %URI{user: "client1", port: port1} = c1
    assert port1 == port(GruuUA1)
    assert URI.get_ext_param(c1, "+sip.instance") == {:ok, instance(GruuUA1)}
    [pub1, tmp1] = gruus(c1)
    assert %URI{user: "client1", domain: "caracola", port: nil, params: [{"gr", _}]} = pub1
    assert %URI{domain: "caracola", params: [{"gr", nil}]} = tmp1
    assert Gruu.get_gruu_pub(GruuUA1) == {:ok, pub1}
    assert Gruu.get_gruu_temp(GruuUA1) == {:ok, tmp1}

    # A second UA with the same AOR
    assert {:ok, 200, [contacts: [c2, ^c1]]} =
             UAC.register(GruuUA2, registrar, [:contact, get_meta: [:contacts]])

    [pub2, tmp2] = gruus(c2)
    assert pub2 != pub1
    assert Gruu.get_gruu_pub(GruuUA2) == {:ok, pub2}

    # Two contacts for the AOR, but one for each GRUU
    assert [_, _] = Registrar.find(GruuRegistrar, :sip, "client1", "caracola")
    assert [%URI{port: ^port1}] = Gruu.registrar_find(GruuRegistrar, pub1)
    assert [%URI{port: ^port1}] = Gruu.registrar_find(GruuRegistrar, tmp1)
    port2 = port(GruuUA2)
    assert [%URI{port: ^port2}] = Gruu.registrar_find(GruuRegistrar, pub2)
    assert [%URI{port: ^port2}] = Gruu.registrar_find(GruuRegistrar, tmp2)

    # GRUUs of the AOR can not be registered
    assert {:ok, 403, []} = UAC.register(GruuUA1, registrar, contact: pub1)
    assert {:ok, 403, []} = UAC.register(GruuUA1, registrar, contact: tmp1)
  end

  test "temporary gruu", %{registrar: registrar} do
    assert {:ok, 200, [call_id: call_id, cseq_num: cseq, contacts: [c1]]} =
             UAC.register(GruuUA1, registrar, [
               :contact,
               get_meta: [:call_id, :cseq_num, :contacts]
             ])

    [_, tmp1] = gruus(c1)

    # The same Call-ID: a new temporary GRUU, and both are valid
    assert {:ok, 200, [contacts: [c2]]} =
             UAC.register(GruuUA1, registrar, [
               :contact,
               call_id: call_id,
               cseq_num: cseq + 1,
               get_meta: [:contacts]
             ])

    [_, tmp2] = gruus(c2)
    assert tmp1 != tmp2
    assert [_] = Gruu.registrar_find(GruuRegistrar, tmp1)
    assert [_] = Gruu.registrar_find(GruuRegistrar, tmp2)

    # A new Call-ID invalidates them
    assert {:ok, 200, [contacts: [c3]]} =
             UAC.register(GruuUA1, registrar, [:contact, get_meta: [:contacts]])

    [_, tmp3] = gruus(c3)
    assert Gruu.registrar_find(GruuRegistrar, tmp1) == []
    assert Gruu.registrar_find(GruuRegistrar, tmp2) == []
    assert [_] = Gruu.registrar_find(GruuRegistrar, tmp3)

    assert {:ok, 200, []} = UAC.register(GruuUA1, registrar, [:unregister_all])
    assert Gruu.registrar_find(GruuRegistrar, tmp3) == []
  end
end
