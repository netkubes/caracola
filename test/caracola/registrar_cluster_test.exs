defmodule Caracola.Registrar.ClusterTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Registrar, UAC}
  alias Caracola.Registrar.{Cluster, Store}
  alias Caracola.Test.{Client, ClusterReg}

  import Caracola.Test.Helpers

  @aor {:sip, "client", "caracola"}

  describe "in a node" do
    setup do
      start_service(Client)
      port = start_service(ClusterReg)
      Registrar.clear(ClusterReg)
      %{registrar: "sip:127.0.0.1:#{port}"}
    end

    test "registrations", %{registrar: registrar} do
      assert {:ok, 200, []} = UAC.register(Client, registrar, [:contact])
      assert [_] = Registrar.find(ClusterReg, @aor)
      assert [{@aor, [_], _expires, _version}] = Store.dump(ClusterReg)

      # Removed AORs are kept without contacts
      assert {:ok, 200, []} = UAC.register(Client, registrar, [:unregister_all])
      assert Registrar.find(ClusterReg, @aor) == []
      assert [{@aor, [], _, _}] = Store.dump(ClusterReg)
      assert Registrar.delete(ClusterReg, :sip, "client", "caracola") == :not_found
    end

    test "the last change wins", %{registrar: registrar} do
      assert {:ok, 200, []} = UAC.register(Client, registrar, [:contact])
      [{@aor, contacts, expires, version}] = Store.dump(ClusterReg)

      # An older change is ignored, a newer one applied
      refute Cluster.apply_change(ClusterReg, {:write, @aor, [], expires, version - 1})
      assert [_] = Registrar.find(ClusterReg, @aor)
      assert Cluster.apply_change(ClusterReg, {:write, @aor, [], expires, version + 1})
      assert Registrar.find(ClusterReg, @aor) == []

      # Syncing merges the newer entries of another node (this one here)
      :ok = Store.load(ClusterReg, [{@aor, contacts, expires, version + 2}])
      assert [_] = Registrar.find(ClusterReg, @aor)
      assert {:ok, _} = Cluster.sync(ClusterReg, node())
    end
  end

  @tag :cluster
  test "registrations are shared among nodes" do
    alias Caracola.Test.Cluster, as: C

    start_service(Client)
    {_p1, n1} = C.start_peer(:caracola_peer1)
    {_p2, n2} = C.start_peer(:caracola_peer2)
    port1 = C.start_service(n1, ClusterReg)
    C.start_service(n2, ClusterReg)

    find = fn node -> :erpc.call(node, Registrar, :find, [ClusterReg, @aor]) end
    nodes = fn node -> :erpc.call(node, Malla.Node, :get_nodes, [ClusterReg]) end
    C.wait(fn -> length(nodes.(n1)) == 2 and length(nodes.(n2)) == 2 end)

    # Registered in node 1, found in node 2
    assert {:ok, 200, []} = UAC.register(Client, "sip:127.0.0.1:#{port1}", [:contact])
    assert [_] = find.(n1)
    C.wait(fn -> length(find.(n2)) == 1 end)

    # A new node gets them when it starts
    {_p3, n3} = C.start_peer(:caracola_peer3)
    C.start_service(n3, ClusterReg)
    C.wait(fn -> length(find.(n3)) == 1 end)

    # Removed in node 2, removed everywhere
    assert :ok = :erpc.call(n2, Registrar, :delete, [ClusterReg, :sip, "client", "caracola"])
    C.wait(fn -> find.(n1) == [] and find.(n3) == [] end)
  end
end
