defmodule CaracolaTest do
  use ExUnit.Case, async: false

  alias Caracola.TestService

  defmodule ReadyUA do
    @moduledoc false
    use Malla.Service,
      plugins: [Caracola],
      sip: [listen: "sip:127.0.0.1:0, <sip:127.0.0.1:0;transport=tcp>"]
  end

  describe "Caracola.wait_ready/2" do
    test "waits for the SIP part of a service started in the background" do
      refute Caracola.ready?(ReadyUA)
      assert Caracola.wait_ready(ReadyUA, 20) == {:error, :timeout}

      start_supervised!(ReadyUA)

      # As in the README: the first request right after starting
      assert Caracola.wait_ready(ReadyUA) == :ok
      assert Caracola.ready?(ReadyUA)
      # UDP and TCP for the first URI, and TCP for the second
      assert length(Caracola.listeners(ReadyUA)) == 3
      [%{local_port: port}] = Caracola.Transport.listeners(ReadyUA, :udp)
      assert {:ok, 200, []} = Caracola.UAC.options(ReadyUA, "sip:127.0.0.1:#{port}")
    end

    test "requests to a service not started yet return an error" do
      assert Caracola.UAC.options(ReadyUA, "sip:127.0.0.1:9") == {:error, :service_not_started}
    end
  end

  describe "Caracola.Config.validate/1" do
    test "fills in NkSIP defaults" do
      assert {:ok, opts} = Caracola.Config.validate([])
      assert opts[:timer_t1] == 500
      assert opts[:timer_t2] == 4000
      assert opts[:max_calls] == 100_000
      assert opts[:local_host] == :auto
      assert "INVITE" in opts[:allow]
      assert opts[:supported] == ["path"]
    end

    test "parses word lists" do
      assert {:ok, opts} =
               Caracola.Config.validate(allow: "INVITE, ACK BYE", events: ["presence"])

      assert opts[:allow] == ["INVITE", "ACK", "BYE"]
      assert opts[:events] == ["presence"]
    end

    test "rejects out of range values" do
      assert {:error, _} = Caracola.Config.validate(timer_t1: 5)
      assert {:error, _} = Caracola.Config.validate(trans_timeout: 4)
      assert {:error, _} = Caracola.Config.validate(allow: [:invite])
      assert {:error, _} = Caracola.Config.validate(unknown: 1)
    end
  end

  describe "service with Caracola plugin" do
    test "starts with validated config" do
      start_supervised!(TestService)
      sip = TestService.get_config()[:sip]
      assert sip[:timer_t1] == 250
      assert sip[:allow] == ["INVITE", "ACK"]
      assert sip[:timer_t2] == 4000
    end

    test "fails to start with invalid config" do
      assert {:error, _} = start_supervised({TestService, [sip: [timer_t1: 1]]})
    end
  end
end
