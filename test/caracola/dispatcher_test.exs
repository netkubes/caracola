defmodule Caracola.DispatcherTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dispatcher, Message, UAC, URI}
  alias Caracola.Test.{Client, DsProxy, Server}

  import Caracola.Test.Helpers

  @dests ["sip:a.example.com", "sip:b.example.com", "sip:c.example.com"]

  defp start_proxy(groups, probe \\ false),
    do: start_service(DsProxy, dispatcher: [groups: groups, probe: probe])

  defp domains(uris), do: Enum.map(uris, & &1.domain)

  test "priority" do
    start_proxy(gws: [destinations: @dests])

    assert domains(Dispatcher.select(DsProxy, :gws)) ==
             ~w(a.example.com b.example.com c.example.com)

    assert domains(Dispatcher.select(DsProxy, :gws, max: 1)) == ~w(a.example.com)
    assert Dispatcher.select(DsProxy, :other) == []

    # Destinations that are down are not used
    :ok = Dispatcher.set_status(DsProxy, "sip:a.example.com", :down)
    assert domains(Dispatcher.select(DsProxy, :gws)) == ~w(b.example.com c.example.com)

    assert [%{status: :down, weight: 1}, %{status: :up}, %{status: :up}] =
             Dispatcher.destinations(DsProxy, :gws)
  end

  test "round robin" do
    start_proxy(gws: [destinations: @dests, strategy: :round_robin])

    firsts = for _ <- 1..4, do: hd(Dispatcher.select(DsProxy, :gws)).domain
    assert firsts == ~w(a.example.com b.example.com c.example.com a.example.com)
    assert length(Dispatcher.select(DsProxy, :gws)) == 3
  end

  test "weighted" do
    start_proxy(
      gws: [
        destinations: [{"sip:a.example.com", 1}, {"sip:b.example.com", 3}],
        strategy: :weighted
      ]
    )

    # 75% expected
    firsts = for _ <- 1..1000, do: hd(Dispatcher.select(DsProxy, :gws)).domain
    assert Enum.count(firsts, &(&1 == "b.example.com")) in 650..850
  end

  test "hash" do
    start_proxy(gws: [destinations: @dests, strategy: :hash])

    order = Dispatcher.select(DsProxy, :gws, key: "call1")
    assert Dispatcher.select(DsProxy, :gws, key: "call1") == order

    # Keys are spread among the destinations
    firsts = for i <- 1..100, uniq: true, do: hd(Dispatcher.select(DsProxy, :gws, key: i)).domain
    assert length(firsts) == 3

    # Without the first destination, the rest keep their order
    [first | rest] = order
    :ok = Dispatcher.set_status(DsProxy, first, :down)
    assert Dispatcher.select(DsProxy, :gws, key: "call1") == rest
  end

  test "routes" do
    start_proxy(gws: [destinations: ["sip:a.example.com", "sip:gw@b.example.com"]])
    {:ok, ruri} = URI.parse_one("sip:alice@example.com")
    req = %Message{class: {:req, :invite}, ruri: ruri, call_id: "c1"}
    call = %Caracola.Call{service: DsProxy}

    assert {:proxy, [[a], [b]], [:record_route]} =
             Dispatcher.route(:gws, req, call, [:record_route])

    assert {a.user, a.domain} == {"alice", "a.example.com"}
    assert {b.user, b.domain} == {"gw", "b.example.com"}

    :ok = Dispatcher.set_status(DsProxy, "sip:a.example.com", :down)
    :ok = Dispatcher.set_status(DsProxy, "sip:gw@b.example.com", :down)
    assert Dispatcher.route(:gws, req, call) == {:reply, :service_unavailable}
  end

  test "failover and health checks" do
    id = make_ref()
    pid = self()

    :telemetry.attach(
      id,
      [:caracola, :dispatcher, :status],
      fn _, _, meta, _ -> send(pid, {:status, meta.uri, meta.status}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    start_service(Client)
    server = start_service(Server)
    # Nothing listens on port 1: TCP connections are refused at once
    dead = "sip:127.0.0.1:1;transport=tcp"
    alive = "sip:127.0.0.1:#{server}"
    port = start_proxy([gws: [destinations: [dead, alive]]], interval: 100, failures: 2)

    # The dead destination fails, and the request goes to the next one
    assert {:ok, 200, [dialog: d1]} =
             UAC.invite(Client, "sip:ok@127.0.0.1:#{port}", [:auto_2xx_ack])

    assert {:ok, 200, []} = UAC.bye(d1)

    # The health checks mark it as down
    assert_receive {:status, "<" <> _ = uri, :down}, 2000
    assert uri =~ "127.0.0.1:1"
    assert [%{status: :down}, %{status: :up}] = Dispatcher.destinations(DsProxy, :gws)
    assert [%URI{port: ^server}] = Dispatcher.select(DsProxy, :gws)

    # Manually up, until the next check
    :ok = Dispatcher.set_status(DsProxy, dead, :up)
    assert_receive {:status, _, :up}
    assert_receive {:status, _, :down}, 2000
  end

  test "configuration errors" do
    assert {:error, {:invalid_dispatcher_group, :gws, {:invalid_destination, "nope:"}}} =
             Dispatcher.plugin_config(nil, dispatcher: [groups: [gws: [destinations: ["nope:"]]]])

    assert {:error, {:invalid_dispatcher_group, :gws, _}} =
             Dispatcher.plugin_config(nil,
               dispatcher: [groups: [gws: [destinations: [], strategy: :other]]]
             )

    assert {:error, {:invalid_dispatcher_probe, _}} =
             Dispatcher.plugin_config(nil, dispatcher: [probe: [interval: 0]])
  end
end
