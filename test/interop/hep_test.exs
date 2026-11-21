defmodule Caracola.Interop.HEPTest do
  # Interoperability of Caracola.HEP with sngrep (its HEP listener), in the
  # nicolaka/netshoot container: sngrep writes the messages it gets to a
  # pcap file, that tshark decodes. Run with `mix test --only hep` (needs
  # docker, see Caracola.Test.Asterisk).
  use ExUnit.Case, async: false

  @moduletag :hep
  @moduletag timeout: 180_000

  alias Caracola.Test.{Asterisk, HepUA, Repl1, Sipp}
  alias Caracola.UAC

  import Caracola.Test.Helpers, only: [start_service: 1, start_service: 2]

  @image "nicolaka/netshoot"

  # sngrep captures for some seconds (only HEP: the interface filter
  # matches nothing), then tshark prints what it got
  @script """
  apk add --no-cache sngrep > /dev/null && echo READY &&
  timeout -s INT 8 sngrep -N -q -L udp:0.0.0.0:9060 -O /tmp/hep.pcap port 1;
  tshark -r /tmp/hep.pcap -n -V
  """

  setup_all do
    if not Asterisk.available?(), do: raise("docker is not available")
    :ok
  end

  defp docker(args) do
    context = System.get_env("ASTERISK_DOCKER_CONTEXT", "orbstack")
    System.cmd("docker", ["--context", context | args], stderr_to_stdout: true)
  end

  defp start_sngrep do
    name = "caracola_hep_#{System.unique_integer([:positive])}"
    port = Sipp.free_port()

    {_, 0} =
      docker(~w(run -d --name #{name} -p 127.0.0.1:#{port}:9060/udp #{@image} sh -c) ++ [@script])

    on_exit(fn -> docker(["rm", "-f", name]) end)
    wait_ready(name, 300)
    # sngrep starts listening
    Process.sleep(1000)
    {name, port}
  end

  defp wait_ready(_name, 0), do: flunk("sngrep did not start")

  defp wait_ready(name, retries) do
    {logs, _} = docker(["logs", name])

    if logs =~ "READY" do
      :ok
    else
      Process.sleep(100)
      wait_ready(name, retries - 1)
    end
  end

  defp output(name) do
    {_, 0} = docker(["wait", name])
    {logs, 0} = docker(["logs", name])
    logs
  end

  test "messages decoded by sngrep" do
    {name, hep_port} = start_sngrep()
    port = start_service(HepUA, hep: [host: "127.0.0.1", port: hep_port, capture_id: 4242])
    start_service(Repl1)

    assert {:ok, 200, [call_id: call_id]} =
             UAC.options(Repl1, "sip:127.0.0.1:#{port}", get_meta: [:call_id])

    out = output(name)
    assert out =~ "Request-Line: OPTIONS sip:127.0.0.1:#{port} SIP/2.0"
    assert out =~ "Status-Line: SIP/2.0 200 OK"
    assert out =~ "Call-ID: #{call_id}"
    # The addresses and ports of the HEP packets
    assert out =~ "Dst Port: #{port}"
    assert out =~ "Src Port: #{port}"
  end
end
