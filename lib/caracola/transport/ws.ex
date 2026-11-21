defmodule Caracola.Transport.WS do
  @moduledoc false
  # WebSocket (RFC 6455) for SIP over WebSocket (RFC 7118): the opening
  # handshake, with the "sip" subprotocol, and framing. Shared by incoming
  # (Caracola.Transport.WSServer) and outgoing (Caracola.Transport.Connection)
  # connections. Each SIP message travels in a WebSocket message, so they
  # are parsed as datagrams.

  alias Caracola.{Parser, Serializer}
  alias Caracola.Transport.{Handler, Port}

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # Maximum size of a handshake or a pending (incomplete) message
  @max_buffer 1_048_576

  @type role :: :server | :client
  @type state :: %{role: role(), buffer: binary(), fragments: nil | {0..15, iodata()}}
  @type send_fun :: (iodata() -> any())

  @spec new(role()) :: state()
  def new(role), do: %{role: role, buffer: "", fragments: nil}

  ## ===================================================================
  ## Handshake
  ## ===================================================================

  @doc """
  Processes the opening handshake received by a server. `path` is the one
  the listener accepts (`nil` for any). Returns the response to send and,
  if accepted, the data after the handshake.
  """
  @spec server_handshake(binary(), String.t() | nil) ::
          {:ok, iodata(), binary()} | {:error, iodata()} | :partial
  def server_handshake(buffer, path) do
    case http(buffer) do
      {:ok, "GET " <> line, headers, rest} ->
        with {:ok, key} <- check_request(line, headers, path) do
          {:ok,
           [
             "HTTP/1.1 101 Switching Protocols\r\n",
             "Upgrade: websocket\r\nConnection: Upgrade\r\n",
             "Sec-WebSocket-Accept: ",
             accept(key),
             "\r\nSec-WebSocket-Protocol: sip\r\n\r\n"
           ], rest}
        end

      {:ok, _line, _headers, _rest} ->
        {:error, http_error("405 Method Not Allowed", [])}

      :partial when byte_size(buffer) > @max_buffer ->
        {:error, http_error("400 Bad Request", [])}

      :partial ->
        :partial

      :error ->
        {:error, http_error("400 Bad Request", [])}
    end
  end

  defp check_request(line, headers, path) do
    cond do
      not ws_path?(line, path) ->
        {:error, http_error("404 Not Found", [])}

      not token?(headers, "upgrade", "websocket") or not token?(headers, "connection", "upgrade") ->
        {:error, http_error("400 Bad Request", [])}

      headers["sec-websocket-version"] != "13" ->
        {:error, http_error("426 Upgrade Required", ["Sec-WebSocket-Version: 13\r\n"])}

      not token?(headers, "sec-websocket-protocol", "sip") ->
        {:error, http_error("400 Bad Request", [])}

      is_binary(headers["sec-websocket-key"]) ->
        {:ok, headers["sec-websocket-key"]}

      true ->
        {:error, http_error("400 Bad Request", [])}
    end
  end

  defp ws_path?(_line, nil), do: true

  defp ws_path?(line, path) do
    [target | _] = String.split(line, " ")
    [target | _] = String.split(target, "?")
    target == path
  end

  defp http_error(status, headers),
    do: ["HTTP/1.1 ", status, "\r\n", headers, "Content-Length: 0\r\n\r\n"]

  @doc "Opening handshake of a client: the request to send and its key."
  @spec client_request(String.t(), String.t()) :: {String.t(), iodata()}
  def client_request(host, path) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    {key,
     [
       "GET ",
       path,
       " HTTP/1.1\r\nHost: ",
       host,
       "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
       "Sec-WebSocket-Key: ",
       key,
       "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: sip\r\n\r\n"
     ]}
  end

  @doc """
  Checks the response to the opening handshake of a client. Returns the data
  after it.
  """
  @spec client_response(binary(), String.t()) :: {:ok, binary()} | {:error, term()} | :partial
  def client_response(buffer, key) do
    case http(buffer) do
      {:ok, "HTTP/1.1 101" <> _, headers, rest} ->
        cond do
          headers["sec-websocket-accept"] != accept(key) -> {:error, :ws_invalid_accept}
          not token?(headers, "sec-websocket-protocol", "sip") -> {:error, :ws_no_sip_protocol}
          true -> {:ok, rest}
        end

      {:ok, "HTTP/1.1 " <> status, _headers, _rest} ->
        {:error, {:ws_rejected, status}}

      :partial when byte_size(buffer) > @max_buffer ->
        {:error, :ws_invalid_response}

      :partial ->
        :partial

      _ ->
        {:error, :ws_invalid_response}
    end
  end

  defp accept(key), do: Base.encode64(:crypto.hash(:sha, key <> @guid))

  # First line, headers (lowercase names) and the rest of the data
  defp http(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [line | lines] = String.split(head, "\r\n")

        case Enum.reduce_while(lines, %{}, &http_header/2) do
          :error -> :error
          headers -> {:ok, line, headers, rest}
        end

      [_] ->
        :partial
    end
  end

  defp http_header(header, acc) do
    case :binary.split(header, ":") do
      [name, value] ->
        name = String.downcase(String.trim(name))
        value = String.trim(value)
        {:cont, Map.update(acc, name, value, &(&1 <> ", " <> value))}

      _ ->
        {:halt, :error}
    end
  end

  defp token?(headers, name, token) do
    case headers[name] do
      nil ->
        false

      value ->
        value
        |> String.downcase()
        |> String.split(",")
        |> Enum.any?(&(String.trim(&1) == token))
    end
  end

  ## ===================================================================
  ## Framing
  ## ===================================================================

  @doc """
  Frames a SIP message: a text message if it is valid UTF-8, binary if not.
  Clients mask their frames.
  """
  @spec frame(iodata(), role()) :: iodata()
  def frame(data, role) do
    data = IO.iodata_to_binary(data)
    opcode = if String.valid?(data), do: 1, else: 2
    frame(opcode, data, role)
  end

  defp frame(opcode, data, role) do
    size = byte_size(data)
    masked = if role == :client, do: 1, else: 0

    header =
      cond do
        size < 126 -> <<1::1, 0::3, opcode::4, masked::1, size::7>>
        size < 65_536 -> <<1::1, 0::3, opcode::4, masked::1, 126::7, size::16>>
        true -> <<1::1, 0::3, opcode::4, masked::1, 127::7, size::64>>
      end

    case role do
      :server ->
        [header, data]

      :client ->
        key = :crypto.strong_rand_bytes(4)
        [header, key, mask(data, key)]
    end
  end

  defp mask("", _key), do: ""

  defp mask(data, key) do
    size = byte_size(data)
    :crypto.exor(data, binary_part(:binary.copy(key, div(size, 4) + 1), 0, size))
  end

  @doc """
  Processes received `data`: SIP messages are given to the port's handler,
  pings are answered and a close frame closes the connection. `send_fun`
  writes to the socket. Returns the new state, or `{:close, reason}`.
  """
  @spec handle_data(binary(), state(), Port.t(), send_fun()) ::
          {:ok, state()} | {:close, term()}
  def handle_data(data, state, port, send_fun),
    do: process(%{state | buffer: state.buffer <> data}, port, send_fun)

  defp process(%{buffer: buffer} = state, port, send_fun) do
    case decode(buffer, state.role) do
      {:ok, fin, opcode, payload, rest} ->
        state = %{state | buffer: rest}

        with {:ok, state} <- event(fin, opcode, payload, state, port, send_fun),
             do: process(state, port, send_fun)

      :partial when byte_size(buffer) > @max_buffer ->
        {:close, :message_too_large}

      :partial ->
        {:ok, state}

      {:error, reason} ->
        send_fun.(frame(8, <<1002::16>>, state.role))
        {:close, reason}
    end
  end

  # Control frames: close, ping and pong
  defp event(_fin, 8, payload, state, _port, send_fun) do
    code = with <<code::16, _::binary>> <- payload, do: <<code::16>>
    send_fun.(frame(8, code, state.role))
    {:close, :normal}
  end

  defp event(_fin, 9, payload, state, _port, send_fun) do
    send_fun.(frame(10, payload, state.role))
    {:ok, state}
  end

  defp event(_fin, 10, _payload, state, _port, _send_fun), do: {:ok, state}

  # Data frames, which may be fragmented
  defp event(fin, opcode, payload, %{fragments: nil} = state, port, send_fun)
       when opcode in [1, 2] do
    if fin == 1,
      do: message(payload, state, port, send_fun),
      else: {:ok, %{state | fragments: {opcode, [payload]}}}
  end

  defp event(fin, 0, payload, %{fragments: {opcode, acc}} = state, port, send_fun) do
    acc = [acc, payload]

    cond do
      fin == 1 -> message(IO.iodata_to_binary(acc), %{state | fragments: nil}, port, send_fun)
      IO.iodata_length(acc) > @max_buffer -> {:close, :message_too_large}
      true -> {:ok, %{state | fragments: {opcode, acc}}}
    end
  end

  defp event(_fin, _opcode, _payload, state, _port, send_fun) do
    send_fun.(frame(8, <<1002::16>>, state.role))
    {:close, :ws_protocol_error}
  end

  defp message(data, state, port, send_fun) do
    # Messages with only whitespace are keepalives
    if String.trim(data) != "", do: parse(data, state, port, send_fun)
    {:ok, state}
  end

  defp parse(data, state, port, send_fun) do
    case Parser.parse(data, port.transport) do
      {:ok, msg, _rest} ->
        Handler.dispatch(port, msg, byte_size(data))

      {:error, error} ->
        with {:ok, reply} <- Serializer.error_response(error),
             do: send_fun.(frame(reply, state.role))
    end
  end

  # Frames from clients must be masked, frames from servers must not
  defp decode(<<fin::1, _rsv::3, opcode::4, masked::1, rest::bitstring>>, role) do
    with true <- masked == if(role == :server, do: 1, else: 0),
         {:ok, size, rest} <- size(rest),
         {:ok, key, rest} <- key(masked, rest),
         <<payload::binary-size(^size), rest::binary>> <- rest do
      payload = if key, do: mask(payload, key), else: payload
      {:ok, fin, opcode, payload, rest}
    else
      false -> {:error, :ws_invalid_mask}
      _ -> :partial
    end
  end

  defp decode(_buffer, _role), do: :partial

  defp size(<<126::7, size::16, rest::binary>>), do: {:ok, size, rest}
  defp size(<<127::7, size::64, rest::binary>>), do: {:ok, size, rest}
  defp size(<<size::7, rest::binary>>) when size < 126, do: {:ok, size, rest}
  defp size(_), do: :partial

  defp key(1, <<key::binary-4, rest::binary>>), do: {:ok, key, rest}
  defp key(0, rest), do: {:ok, nil, rest}
  defp key(_masked, _rest), do: :partial
end
