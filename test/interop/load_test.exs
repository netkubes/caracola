defmodule Caracola.Interop.LoadTest do
  # Load tests with SIPp. Run with `mix test --only load`. The number of
  # calls and the rate can be changed with LOAD_CALLS and LOAD_RATE.
  use ExUnit.Case, async: false

  @moduletag :load
  @moduletag timeout: :infinity

  alias Caracola.Interop.{Proxy, UAS}
  alias Caracola.Test.Sipp

  import Caracola.Test.Helpers, only: [start_service: 2, start_service: 1]

  defp calls, do: String.to_integer(System.get_env("LOAD_CALLS", "5000"))
  defp rate, do: String.to_integer(System.get_env("LOAD_RATE", "500"))

  defp sipp_uac(target, args, timeout) do
    Sipp.run(["-i", "127.0.0.1", "-p", "#{Sipp.free_port()}", target] ++ args, timeout: timeout)
  end

  defp report(name, result) do
    IO.puts("\n== #{name}: #{result.ok} ok, #{result.failed} failed\n#{Sipp.summary(result)}")
    assert %{status: 0, failed: 0} = result
  end

  defp timeout, do: div(calls(), rate()) + 60

  test "SIPp UAC to Caracola UAS (INVITE, ACK, BYE over UDP)" do
    port = start_service(UAS)

    args = [
      "-sn",
      "uac",
      "-s",
      "test",
      "-m",
      "#{calls()}",
      "-r",
      "#{rate()}",
      "-l",
      "#{rate() * 4}"
    ]

    report("UAS", sipp_uac("127.0.0.1:#{port}", args, timeout()))
  end

  test "SIPp UAC to Caracola UAS (OPTIONS over UDP)" do
    # Over UDP, each transaction keeps its call for 64 * T1 (32 s) after
    # the response, to absorb retransmissions
    port = start_service(UAS, sip: [max_calls: 1_000_000])
    memory = :erlang.memory(:processes)
    args = ["-sf", Sipp.scenario("options.xml"), "-m", "#{calls() * 4}", "-r", "#{rate() * 4}"]
    result = sipp_uac("127.0.0.1:#{port}", args, timeout())
    calls = Caracola.Call.count(UAS)
    per_call = div(:erlang.memory(:processes) - memory, max(calls, 1))
    IO.puts("\n== OPTIONS: #{calls} live calls, #{per_call} bytes per call")
    report("OPTIONS", result)
  end

  for mode <- [:stateful, :stateless] do
    test "SIPp through a Caracola #{mode} proxy" do
      sport = Sipp.free_port()
      uas_args = ["-sn", "uas", "-i", "127.0.0.1", "-p", "#{sport}", "-m", "#{calls()}"]
      uas = Sipp.async(uas_args, timeout: timeout())
      Process.sleep(500)

      pport =
        start_service(Proxy,
          target: "sip:service@127.0.0.1:#{sport}",
          stateless: unquote(mode) == :stateless
        )

      args = [
        "-sf",
        Sipp.scenario("uac_rr.xml"),
        "-s",
        "service",
        "-m",
        "#{calls()}",
        "-r",
        "#{rate()}",
        "-l",
        "#{rate() * 4}"
      ]

      report("#{unquote(mode)} proxy (UAC)", sipp_uac("127.0.0.1:#{pport}", args, timeout()))
      report("#{unquote(mode)} proxy (UAS)", Task.await(uas, :infinity))
    end
  end
end
