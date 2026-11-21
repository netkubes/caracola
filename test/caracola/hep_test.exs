defmodule Caracola.HEPTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{HEP, UAC}
  alias Caracola.Test.{HepUA, Repl1}

  import Caracola.Test.Helpers

  test "encode and decode" do
    packet = %{
      src_ip: {10, 0, 0, 1},
      dst_ip: {0, 0, 0, 0, 0, 0, 0, 1},
      src_port: 5060,
      dst_port: 5070,
      transport: :tcp,
      time: 1_700_000_000_123_456,
      capture_id: 7,
      password: "secret",
      correlation_id: "abc",
      payload: "OPTIONS sip:a@b SIP/2.0\r\n\r\n"
    }

    assert <<"HEP3", len::16, _::binary>> = bin = HEP.encode(packet)
    assert len == byte_size(bin)
    assert HEP.decode(bin) == {:ok, packet}
    assert HEP.decode("HEP3") == :error
  end

  test "messages are captured" do
    {:ok, homer} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
    {:ok, homer_port} = :inet.port(homer)

    port = start_service(HepUA, hep: [host: "127.0.0.1", port: homer_port, capture_id: 42])
    start_service(Repl1)

    assert {:ok, 200, [call_id: call_id]} =
             UAC.options(Repl1, "sip:127.0.0.1:#{port}", get_meta: [:call_id])

    # The request received and the response sent
    packets =
      for _ <- 1..2 do
        assert_receive {:udp, ^homer, _, _, data}, 2000
        {:ok, packet} = HEP.decode(data)
        packet
      end

    assert [request, response] = packets
    assert request.payload =~ "OPTIONS sip:"
    assert response.payload =~ "SIP/2.0 200"
    assert request.dst_port == port and response.src_port == port
    assert request.src_port == response.dst_port
    assert request.transport == :udp and request.capture_id == 42
    assert request.correlation_id == call_id
    refute_receive {:udp, ^homer, _, _, _}, 200

    # Stopped with the service
    stop_supervised!(HepUA)

    assert :telemetry.list_handlers([:caracola, :message, :sent])
           |> Enum.all?(&(&1.id != {HEP, HepUA}))
  end
end
