defmodule Caracola.Transport.Stream do
  @moduledoc false
  # Framing for stream transports (TCP, TLS), shared by incoming and outgoing
  # connections. Splits the buffered data into SIP messages, answers RFC 5626
  # keepalives (CRLFCRLF ping, CRLF pong) and replies 400 to invalid requests.

  alias Caracola.{Parser, Serializer}
  alias Caracola.Transport.{Handler, Port}

  # Maximum size of a pending (incomplete) message
  @max_buffer 1_048_576

  @type send_fun :: (iodata() -> any())

  @doc """
  Processes received `data`. Returns the new buffer, or `{:close, reason}` if
  the connection must be closed.
  """
  @spec handle_data(binary(), binary(), Port.t(), send_fun()) ::
          {:ok, binary()} | {:close, term()}
  def handle_data(data, buffer, port, send_fun), do: process(buffer <> data, port, send_fun)

  defp process("", _port, _send_fun), do: {:ok, ""}

  defp process("\r\n\r\n" <> rest, port, send_fun) do
    send_fun.("\r\n")
    process(rest, port, send_fun)
  end

  # A pong (or a ping still incomplete, that will be treated as a pong),
  # notified to the connection process (see Caracola.Transport.Keepalive)
  defp process("\r\n" <> rest, port, send_fun)
       when rest == "" or binary_part(rest, 0, 1) != "\r" do
    send(self(), :keepalive_pong)
    process(rest, port, send_fun)
  end

  defp process(bin, port, send_fun) do
    case Parser.parse(bin, port.transport) do
      {:ok, msg, rest} ->
        Handler.dispatch(port, msg, byte_size(bin) - byte_size(rest))
        process(rest, port, send_fun)

      :partial when byte_size(bin) > @max_buffer ->
        {:close, :message_too_large}

      :partial ->
        {:ok, bin}

      {:error, error} ->
        with {:ok, reply} <- Serializer.error_response(error), do: send_fun.(reply)
        {:close, :invalid_message}
    end
  end
end
