defmodule Caracola.HEP do
  @moduledoc """
  HEP capture: sends every SIP message received or sent by the service to
  a capture server (Homer, heplify-server...) with HEPv3 over UDP, from the
  `[:caracola, :message, :received]` and `[:caracola, :message, :sent]`
  telemetry events (see `Caracola.Telemetry`).

  ```
  defmodule MyProxy do
    use Malla.Service,
      plugins: [Caracola.HEP],
      sip: [listen: "sip:all:5060"],
      hep: [host: "homer.example.com", port: 9060, capture_id: 101]
  end
  ```

  The capture starts and stops with the service. Each packet carries the
  addresses and ports of both sides, the transport, the time, the
  capture agent id, the Call-ID (as correlation id) and the message.
  Keepalives are not sent. Messages are captured as parsed and
  serialized again by Caracola, which may differ from the bytes on the
  wire in spacing or header order.

  ## Configuration

  Under the `:hep` key:

    * `:host` - the capture server (a hostname or an IP, required).
    * `:port` - its UDP port (default 9060).
    * `:capture_id` - the capture agent id (default 2001).
    * `:password` - the authentication key, if the server needs one.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.{Message, Serializer}
  alias Caracola.Transport.Port

  @schema NimbleOptions.new!(
            host: [type: :string, required: true],
            port: [type: {:in, 1..65_535}, default: 9060],
            capture_id: [type: :non_neg_integer, default: 2001],
            password: [type: :string]
          )

  @events [[:caracola, :message, :received], [:caracola, :message, :sent]]

  @typedoc "A HEP packet, as encoded by `encode/1` and decoded by `decode/1`."
  @type packet :: %{
          src_ip: :inet.ip_address(),
          dst_ip: :inet.ip_address(),
          src_port: :inet.port_number(),
          dst_port: :inet.port_number(),
          transport: :udp | :tcp,
          time: integer(),
          capture_id: non_neg_integer(),
          password: String.t() | nil,
          correlation_id: String.t() | nil,
          payload: binary()
        }

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Encodes a HEPv3 packet with a SIP message. `time` is in microseconds of
  system time.
  """
  @spec encode(packet()) :: binary()
  def encode(packet) do
    {family, src, dst} =
      case {packet.src_ip, packet.dst_ip} do
        {{_, _, _, _} = src, {_, _, _, _} = dst} -> {2, chunk(3, ip(src)), chunk(4, ip(dst))}
        {src, dst} -> {10, chunk(5, ip(src)), chunk(6, ip(dst))}
      end

    proto = if packet.transport == :udp, do: 17, else: 6
    secs = div(packet.time, 1_000_000)
    usecs = rem(packet.time, 1_000_000)

    chunks = [
      chunk(1, <<family>>),
      chunk(2, <<proto>>),
      src,
      dst,
      chunk(7, <<packet.src_port::16>>),
      chunk(8, <<packet.dst_port::16>>),
      chunk(9, <<secs::32>>),
      chunk(10, <<usecs::32>>),
      # SIP
      chunk(11, <<1>>),
      chunk(12, <<packet.capture_id::32>>),
      if(packet[:password], do: chunk(14, packet.password), else: []),
      chunk(15, packet.payload),
      if(packet[:correlation_id], do: chunk(17, packet.correlation_id), else: [])
    ]

    body = IO.iodata_to_binary(chunks)
    <<"HEP3", byte_size(body) + 6::16, body::binary>>
  end

  @doc "Decodes a HEPv3 packet (for tests and tools)."
  @spec decode(binary()) :: {:ok, packet()} | :error
  def decode(<<"HEP3", len::16, rest::binary>>) when byte_size(rest) == len - 6 do
    chunks = for {type, value} <- chunks(rest, []), into: %{}, do: {type, value}

    {:ok,
     %{
       src_ip: ip_value(chunks[3] || chunks[5]),
       dst_ip: ip_value(chunks[4] || chunks[6]),
       src_port: uint(chunks[7]),
       dst_port: uint(chunks[8]),
       transport: if(uint(chunks[2]) == 17, do: :udp, else: :tcp),
       time: uint(chunks[9]) * 1_000_000 + uint(chunks[10]),
       capture_id: uint(chunks[12]),
       password: chunks[14],
       correlation_id: chunks[17],
       payload: chunks[15]
     }}
  rescue
    _ -> :error
  end

  def decode(_bin), do: :error

  defp chunk(type, value), do: [<<0::16, type::16, byte_size(value) + 6::16>>, value]

  defp chunks(<<>>, acc), do: Enum.reverse(acc)

  defp chunks(<<_vendor::16, type::16, len::16, rest::binary>>, acc) do
    size = len - 6
    <<value::binary-size(^size), rest::binary>> = rest
    chunks(rest, [{type, value} | acc])
  end

  defp ip({a, b, c, d}), do: <<a, b, c, d>>
  defp ip(ip), do: for(n <- Tuple.to_list(ip), into: <<>>, do: <<n::16>>)

  defp ip_value(<<a, b, c, d>>), do: {a, b, c, d}
  defp ip_value(<<_::binary-16>> = bin), do: List.to_tuple(for <<n::16 <- bin>>, do: n)

  defp uint(bin), do: :binary.decode_unsigned(bin)

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <- NimbleOptions.validate(Keyword.get(config, :hep, []), @schema),
         do: {:ok, Keyword.put(config, :hep, opts)}
  end

  @impl true
  def plugin_start(srv_id, config),
    do: {:ok, children: [{__MODULE__.Capture, {srv_id, config[:hep]}}]}

  @doc false
  # Telemetry handler: sends the message to the capture server
  def handle_event([:caracola, :message, dir], _measurements, meta, %{service: service} = state)
      when meta.service == service and is_struct(meta.message, Message) do
    %Port{} = port = meta.port

    {src_ip, src_port, dst_ip, dst_port} =
      if dir == :received,
        do: {port.remote_ip, port.remote_port, port.local_ip, port.local_port},
        else: {port.local_ip, port.local_port, port.remote_ip, port.remote_port}

    packet =
      encode(%{
        src_ip: src_ip,
        dst_ip: dst_ip,
        src_port: src_port,
        dst_port: dst_port,
        transport: if(port.transport == :udp, do: :udp, else: :tcp),
        time: System.os_time(:microsecond),
        capture_id: state.capture_id,
        password: state.password,
        correlation_id: meta.message.call_id,
        payload: IO.iodata_to_binary(Serializer.to_iodata(meta.message))
      })

    :gen_udp.send(state.socket, state.host, state.port, packet)
    :ok
  end

  def handle_event(_event, _measurements, _meta, _state), do: :ok

  defmodule Capture do
    @moduledoc false
    # Owns the socket and the telemetry handler of a service
    use GenServer

    require Logger

    def start_link({service, opts}), do: GenServer.start_link(__MODULE__, {service, opts})

    @impl true
    def init({service, opts}) do
      Process.flag(:trap_exit, true)

      with {:ok, host} <- resolve(opts[:host]),
           {:ok, socket} <- :gen_udp.open(0, [:binary, inet_family(host), active: false]) do
        state = %{
          service: service,
          socket: socket,
          host: host,
          port: opts[:port],
          capture_id: opts[:capture_id],
          password: opts[:password]
        }

        id = {Caracola.HEP, service}
        :telemetry.attach_many(id, Caracola.HEP.events(), &Caracola.HEP.handle_event/4, state)
        {:ok, id}
      else
        {:error, error} ->
          Logger.warning("HEP capture not started: #{inspect(error)}")
          {:stop, error}
      end
    end

    @impl true
    def terminate(_reason, id), do: :telemetry.detach(id)

    defp resolve(host) do
      charlist = String.to_charlist(host)

      case :inet.parse_address(charlist) do
        {:ok, ip} -> {:ok, ip}
        _ -> :inet.getaddr(charlist, :inet)
      end
    end

    defp inet_family({_, _, _, _}), do: :inet
    defp inet_family(_ip), do: :inet6
  end

  @doc false
  def events, do: @events
end
