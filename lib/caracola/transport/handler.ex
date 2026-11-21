defmodule Caracola.Transport.Handler do
  @moduledoc """
  Receives the SIP messages arriving at a listener or connection.

  Handlers are given as `{module, arg}` and called in the process owning the
  socket, so they should hand the message over to another process quickly.
  The `Caracola.Transport.Port` identifies where the message came from, and
  can be used to reply with `Caracola.Transport.send/2`.
  """

  alias Caracola.Message
  alias Caracola.Transport.Port

  @typedoc "A handler: a module implementing this behaviour and the argument given to its callback."
  @type t :: {module(), term()}

  @doc """
  Called for each message received, in the process owning the socket. The
  return value is ignored.
  """
  @callback handle_message(Port.t(), Message.t(), arg :: term()) :: any()

  @doc false
  # Gives a received message (of `size` bytes) to the handler
  @spec dispatch(Port.t(), Message.t(), non_neg_integer()) :: :ok
  def dispatch(%Port{handler: handler} = port, msg, size) do
    Caracola.Telemetry.received(port, msg, size)

    case handler do
      {module, arg} -> module.handle_message(port, msg, arg)
      nil -> :ok
    end

    :ok
  end
end
