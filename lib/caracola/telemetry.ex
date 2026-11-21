defmodule Caracola.Telemetry do
  @moduledoc """
  `:telemetry` events emitted by Caracola. They replace NkSIP's trace,
  stats and debug facilities: attach handlers with `:telemetry.attach/4` to
  log messages, collect metrics (for example with `Telemetry.Metrics`) or
  trace calls.

  All events carry the `:service` in their metadata.

  ## Messages

    * `[:caracola, :message, :received]` - a SIP message was received.
      Measurements: `:size` (bytes). Metadata: `:message`
      (`t:Caracola.Message.t/0`) and `:port` (`t:Caracola.Transport.Port.t/0`).
    * `[:caracola, :message, :sent]` - a SIP message (or keepalive) was
      sent. Measurements: `:size` (bytes). Metadata: `:message` (`nil` for
      raw data) and `:port`.

  ## Calls

    * `[:caracola, :call, :start]` - a call process (one per Call-ID) was
      started. Measurements: `:system_time` and `:monotonic_time`. Metadata:
      `:call_id`.
    * `[:caracola, :call, :stop]` - the call process finished. Measurements:
      `:duration` and `:monotonic_time`. Metadata: `:call_id`.

  ## Transactions

    * `[:caracola, :uac, :stop]` - a client transaction received its first
      final response. Measurements: `:duration` (since the request was
      created) and `:monotonic_time`. Metadata: `:call_id`, `:method` and `:code`.
    * `[:caracola, :uas, :stop]` - a server transaction sent its first final
      response. Measurements: `:duration` (since the request was received)
      and `:monotonic_time`.
      Metadata: `:call_id`, `:method` and `:code`.

  ## Dialogs

    * `[:caracola, :dialog, :start]` - a dialog was created. Measurements:
      `:system_time` and `:monotonic_time`. Metadata: `:call_id` and
      `:dialog_id`.
    * `[:caracola, :dialog, :stop]` - a dialog was removed. Measurements:
      `:duration` and `:monotonic_time`. Metadata: `:call_id` and
      `:dialog_id`.

  ## Plugins

    * `[:caracola, :rate_limit, :reject]` and `[:caracola, :rate_limit, :ban]` -
      see `Caracola.RateLimit`.
    * `[:caracola, :dispatcher, :status]` - see `Caracola.Dispatcher`.
    * `[:caracola, :overload_control, :drop]` - see `Caracola.OverloadControl`.

  Durations are in `:native` time units, see `System.convert_time_unit/3`.
  """

  require Logger

  alias Caracola.{Message, Serializer}
  alias Caracola.Transport.Port

  @trace_id {__MODULE__, :trace}

  @doc """
  Logs every SIP message sent or received (with `Logger.info/2`), like
  NkSIP's `nksip_trace`. `trace(false)` stops it.
  """
  @spec trace(boolean()) :: :ok
  def trace(true) do
    events = [[:caracola, :message, :received], [:caracola, :message, :sent]]

    case :telemetry.attach_many(@trace_id, events, &__MODULE__.handle_trace/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  def trace(false) do
    :telemetry.detach(@trace_id)
    :ok
  end

  @doc false
  def handle_trace(
        [:caracola, :message, dir],
        _measurements,
        %{message: %Message{} = msg} = meta,
        _
      ) do
    %Port{transport: transport, remote_ip: ip, remote_port: port} = meta.port
    arrow = if dir == :sent, do: "->", else: "<-"
    peer = "#{transport}:#{Caracola.Util.ip_to_host(ip)}:#{port}"

    Logger.info(
      "SIP #{inspect(meta.service)} #{arrow} #{peer}\n" <>
        IO.iodata_to_binary(Serializer.to_iodata(msg))
    )
  end

  def handle_trace(_event, _measurements, _meta, _config), do: :ok

  @doc false
  @spec received(Port.t(), Message.t(), non_neg_integer()) :: :ok
  def received(%Port{} = port, %Message{} = msg, size) do
    :telemetry.execute([:caracola, :message, :received], %{size: size}, %{
      service: port.service,
      message: msg,
      port: port
    })
  end

  @doc false
  @spec sent(Port.t(), Message.t() | iodata(), iodata()) :: :ok
  def sent(%Port{} = port, msg, data) do
    :telemetry.execute([:caracola, :message, :sent], %{size: IO.iodata_length(data)}, %{
      service: port.service,
      message: if(is_struct(msg, Message), do: msg),
      port: port
    })
  end

  @doc false
  @spec start(atom(), map()) :: integer()
  def start(name, meta) do
    time = System.monotonic_time()

    :telemetry.execute(
      [:caracola, name, :start],
      %{system_time: System.system_time(), monotonic_time: time},
      meta
    )

    time
  end

  @doc false
  @spec stop(atom(), integer(), map()) :: :ok
  def stop(name, start_time, meta) do
    time = System.monotonic_time()

    :telemetry.execute(
      [:caracola, name, :stop],
      %{duration: time - start_time, monotonic_time: time},
      meta
    )
  end
end
