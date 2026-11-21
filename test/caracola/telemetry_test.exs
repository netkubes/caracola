defmodule Caracola.TelemetryTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Message, UAC}
  alias Caracola.Test.{Client, Server}

  import Caracola.Test.Helpers

  @events [
    [:caracola, :message, :received],
    [:caracola, :message, :sent],
    [:caracola, :call, :start],
    [:caracola, :call, :stop],
    [:caracola, :uac, :stop],
    [:caracola, :uas, :stop],
    [:caracola, :dialog, :start],
    [:caracola, :dialog, :stop]
  ]

  setup do
    id = make_ref()
    pid = self()

    :telemetry.attach_many(
      id,
      @events,
      fn event, measurements, meta, _ -> send(pid, {:telemetry, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "events" do
    port = start()
    uri = "<sip:127.0.0.1:#{port};transport=tcp>"

    assert {:ok, 200, [call_id: call_id]} = UAC.options(Client, uri, get_meta: [:call_id])

    assert_receive {:telemetry, [:caracola, :call, :start], %{system_time: _},
                    %{service: Client, call_id: ^call_id}}

    assert_receive {:telemetry, [:caracola, :message, :sent], %{size: size},
                    %{service: Client, message: %Message{class: {:req, :options}}}}

    assert_receive {:telemetry, [:caracola, :message, :received], %{size: ^size},
                    %{service: Server, message: %Message{class: {:req, :options}}}}

    assert_receive {:telemetry, [:caracola, :uas, :stop], %{duration: _},
                    %{service: Server, call_id: ^call_id, method: :options, code: 200}}

    assert_receive {:telemetry, [:caracola, :uac, :stop], %{duration: d},
                    %{service: Client, call_id: ^call_id, method: :options, code: 200}}

    assert d > 0

    # TCP transactions end at once
    assert_receive {:telemetry, [:caracola, :call, :stop], %{duration: _},
                    %{service: Client, call_id: ^call_id}}

    assert {:ok, 200, [dialog: dialog]} = UAC.invite(Client, uri, [{:add, "x-op", "ok"}])
    {:dialog, _, call_id, dialog_id} = dialog

    assert_receive {:telemetry, [:caracola, :dialog, :start], _,
                    %{service: Client, call_id: ^call_id, dialog_id: ^dialog_id}}

    assert UAC.ack(dialog) == :ok
    assert {:ok, 200, []} = UAC.bye(dialog)

    assert_receive {:telemetry, [:caracola, :dialog, :stop], %{duration: _},
                    %{service: Client, dialog_id: ^dialog_id}}

    assert_receive {:telemetry, [:caracola, :dialog, :stop], _,
                    %{service: Server, call_id: ^call_id}}
  end

  test "trace" do
    port = start()
    Caracola.Telemetry.trace(true)
    level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Caracola.Telemetry.trace(false)
      Logger.configure(level: level)
    end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert {:ok, 200, []} = UAC.options(Client, "sip:127.0.0.1:#{port}")
      end)

    assert log =~ "SIP Caracola.Test.Client -> udp:127.0.0.1:#{port}"
    assert log =~ "OPTIONS sip:127.0.0.1:#{port} SIP/2.0"
    assert log =~ "SIP Caracola.Test.Server <- udp:127.0.0.1"
    assert log =~ "SIP/2.0 200 OK"
  end
end
