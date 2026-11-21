defmodule Caracola.TestHandler do
  @moduledoc false
  # Transport handler sending received messages to a process
  @behaviour Caracola.Transport.Handler

  @impl true
  def handle_message(port, msg, pid), do: send(pid, {:sip, port, msg})
end
