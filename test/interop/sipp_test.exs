defmodule Caracola.Interop.SippTest do
  # Interoperability with SIPp. Run with `mix test --only sipp`.
  use ExUnit.Case, async: false

  @moduletag :sipp
  @moduletag timeout: 180_000

  alias Caracola.Interop.{Proxy, UAC, UAS}
  alias Caracola.SDP
  alias Caracola.Test.Sipp

  import Caracola.Test.Helpers, only: [start_service: 2, start_service: 1]

  setup_all do
    if not Sipp.available?(), do: raise("sipp is not installed")
    :ok
  end

  defp sipp_uac(target, args),
    do: Sipp.run(["-i", "127.0.0.1", "-p", "#{Sipp.free_port()}", target] ++ args)

  defp assert_calls(result, calls) do
    assert %{status: 0, ok: ^calls, failed: 0} = result, Sipp.summary(result)
  end

  describe "SIPp as UAC, Caracola as UAS" do
    for {transport, t} <- [udp: "u1", tcp: "t1"] do
      test "INVITE, ACK and BYE over #{transport}" do
        port = start_service(UAS)

        result =
          sipp_uac("127.0.0.1:#{port}", [
            "-sn",
            "uac",
            "-s",
            "test",
            "-t",
            unquote(t),
            "-m",
            "20",
            "-r",
            "20"
          ])

        assert_calls(result, 20)
      end
    end

    test "INVITE, ACK and BYE over tls" do
      {server_tls, _client_tls} = Caracola.Tutorial.tls_config()

      start_service(UAS,
        sip: [listen: "sip:127.0.0.1:0, <sip:127.0.0.1:0;transport=tls>", tls: server_tls]
      )

      [%{local_port: port}] = Caracola.Transport.listeners(UAS, :tls)

      result =
        sipp_uac("127.0.0.1:#{port}", [
          "-sn",
          "uac",
          "-s",
          "test",
          "-t",
          "l1",
          "-m",
          "20",
          "-r",
          "20"
        ])

      assert_calls(result, 20)
    end

    test "OPTIONS" do
      port = start_service(UAS)

      result =
        sipp_uac("127.0.0.1:#{port}", [
          "-sf",
          Sipp.scenario("options.xml"),
          "-m",
          "20",
          "-r",
          "20"
        ])

      assert_calls(result, 20)
    end

    test "REGISTER" do
      port = start_service(UAS)

      result =
        sipp_uac("127.0.0.1:#{port}", [
          "-sf",
          Sipp.scenario("register.xml"),
          "-m",
          "10",
          "-r",
          "10"
        ])

      assert_calls(result, 10)
    end

    test "REGISTER with digest authentication" do
      port = start_service(UAS, auth: true)

      result =
        sipp_uac("127.0.0.1:#{port}", [
          "-sf",
          Sipp.scenario("register_auth.xml"),
          "-m",
          "10",
          "-r",
          "10"
        ])

      assert_calls(result, 10)
    end
  end

  describe "Caracola as UAC, SIPp as UAS" do
    for {transport, t} <- [udp: "u1", tcp: "t1"] do
      test "INVITE, ACK and BYE over #{transport}" do
        start_service(UAC)
        sport = Sipp.free_port()

        uas =
          Sipp.async([
            "-sn",
            "uas",
            "-i",
            "127.0.0.1",
            "-p",
            "#{sport}",
            "-t",
            unquote(t),
            "-m",
            "10"
          ])

        Process.sleep(500)
        uri = "<sip:service@127.0.0.1:#{sport};transport=#{unquote(transport)}>"
        sdp = SDP.new("127.0.0.1", [{"audio", 4000, [{:rtpmap, 0, "PCMU/8000"}]}])

        for _ <- 1..10 do
          assert {:ok, 200, [dialog: dialog]} =
                   Caracola.UAC.invite(UAC, uri, [:auto_2xx_ack, body: sdp])

          assert {:ok, 200, []} = Caracola.UAC.bye(dialog)
        end

        assert_calls(Task.await(uas, 70_000), 10)
      end
    end
  end

  describe "SIPp through a Caracola proxy" do
    for mode <- [:stateful, :stateless] do
      test "#{mode}" do
        sport = Sipp.free_port()
        uas = Sipp.async(["-sn", "uas", "-i", "127.0.0.1", "-p", "#{sport}", "-m", "20"])
        Process.sleep(500)

        pport =
          start_service(Proxy,
            target: "sip:service@127.0.0.1:#{sport}",
            stateless: unquote(mode) == :stateless
          )

        result =
          sipp_uac("127.0.0.1:#{pport}", [
            "-sf",
            Sipp.scenario("uac_rr.xml"),
            "-s",
            "service",
            "-m",
            "20",
            "-r",
            "20"
          ])

        assert_calls(result, 20)
        assert_calls(Task.await(uas, 70_000), 20)
      end
    end
  end
end
