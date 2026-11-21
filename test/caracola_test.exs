defmodule CaracolaTest do
  use ExUnit.Case, async: false

  alias Caracola.TestService

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
