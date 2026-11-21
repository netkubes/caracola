defmodule Caracola.RateLimitTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{RateLimit, UAC}
  alias Caracola.Test.{Client, RlServer}

  import Caracola.Test.Helpers

  @local {127, 0, 0, 1}

  setup do
    RateLimit.clear(RlServer)
    id = make_ref()
    pid = self()

    :telemetry.attach_many(
      id,
      [[:caracola, :rate_limit, :reject], [:caracola, :rate_limit, :ban]],
      fn event, measurements, meta, _ -> send(pid, {:telemetry, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp start_server(config, extra \\ []) do
    start_service(Client)
    port = start_service(RlServer, [rate_limit: config] ++ extra)
    "sip:127.0.0.1:#{port}"
  end

  defp options(uri, opts \\ []) do
    case UAC.options(Client, uri, opts) do
      {:ok, code, _} -> code
      {:error, {:exit, :timeout}} -> :timeout
      {:error, error} -> error
    end
  end

  test "requests per address" do
    uri = start_server(per_ip: {3, 60_000})

    assert for(_ <- 1..5, do: options(uri)) == [200, 200, 200, 503, 503]

    assert_receive {:telemetry, [:caracola, :rate_limit, :reject], %{count: 1},
                    %{service: RlServer, ip: @local, reason: :per_ip}}
  end

  test "requests over the limit can be dropped" do
    uri = start_server(per_ip: {1, 60_000}, reply: :drop)
    assert options(uri) == 200
    assert options(uri, timeout: 300) == :timeout
  end

  test "requests per user" do
    uri = start_server(per_ip: nil, per_user: {2, 60_000})

    assert for(_ <- 1..3, do: options(uri)) == [200, 200, 503]
    assert options(uri, from: "<sip:other@caracola>") == 200

    assert_receive {:telemetry, [:caracola, :rate_limit, :reject], _, %{reason: :per_user}}
  end

  test "exempt addresses" do
    uri = start_server(per_ip: {1, 60_000}, exempt: ["127.0.0.0/8"])
    assert for(_ <- 1..3, do: options(uri)) == [200, 200, 200]
  end

  test "scanners are banned" do
    uri = start_server([])

    assert options(uri, [{:replace, "user-agent", "friendly-scanner"}, timeout: 300]) == :timeout
    assert RateLimit.banned?(RlServer, @local)
    assert [{@local, left}] = RateLimit.bans(RlServer)
    assert left > 590_000

    assert_receive {:telemetry, [:caracola, :rate_limit, :ban], %{time: 600_000},
                    %{ip: @local, reason: :scanner}}

    # Everything from a banned address is dropped
    assert options(uri, timeout: 300) == :timeout

    assert_receive {:telemetry, [:caracola, :rate_limit, :reject], _, %{reason: :banned}}

    RateLimit.unban(RlServer, @local)
    assert options(uri) == 200
  end

  test "authentication failures ban the address" do
    uri =
      start_server([auth_failures: {2, 60_000}, ban_time: 200],
        auth: [realm: "caracola"],
        passwords: %{"client" => "secret"}
      )

    assert options(uri, password: "secret") == 200
    assert options(uri, password: "wrong") == 403
    assert options(uri, password: "wrong") == 403
    refute RateLimit.banned?(RlServer, @local)
    assert options(uri, password: "wrong") == 403
    assert RateLimit.banned?(RlServer, @local)

    assert_receive {:telemetry, [:caracola, :rate_limit, :ban], %{time: 200},
                    %{reason: :auth_failures}}

    assert options(uri, password: "secret", timeout: 100) == :timeout

    # The ban expires
    Process.sleep(200)
    assert options(uri, password: "secret") == 200
  end

  test "manual bans" do
    start_server([])
    :ok = RateLimit.ban(RlServer, {192, 0, 2, 1}, 1000)
    assert RateLimit.banned?(RlServer, {192, 0, 2, 1})
    refute RateLimit.banned?(RlServer, @local)
    :ok = RateLimit.unban(RlServer, {192, 0, 2, 1})
    assert RateLimit.bans(RlServer) == []
  end

  test "configuration errors" do
    assert {:error, {:invalid_network, "10.0.0.0/40"}} =
             RateLimit.plugin_config(nil, rate_limit: [exempt: ["10.0.0.0/40"]])

    assert {:error, %NimbleOptions.ValidationError{}} =
             RateLimit.plugin_config(nil, rate_limit: [per_ip: 10])
  end
end
