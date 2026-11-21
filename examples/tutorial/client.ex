defmodule Caracola.Tutorial.Client do
  @moduledoc """
  Callbacks of the clients of the [tutorial](03-tutorial.md), used by
  `Caracola.Tutorial.Client1` and `Caracola.Tutorial.Client2`.
  """

  defmacro __using__(_opts) do
    quote do
      alias Caracola.SDP

      # OPTIONS are answered with the name of the service in a header
      defcb sip_options(_req, call) do
        name = call.service |> Module.split() |> List.last() |> String.downcase()
        {:reply, {:ok, [{:add, "x-caracola-id", name}, :contact, :allow, :accept, :supported]}}
      end

      # An INVITE with SDP rings for two seconds and is answered with the
      # same SDP (from another process). Without SDP, it is rejected.
      defcb sip_invite(req, _call) do
        case SDP.from_message(req) do
          %SDP{} = sdp ->
            spawn(fn ->
              :ok = Caracola.reply(req, :ringing)
              Process.sleep(2000)
              Caracola.reply(req, {:answer, sdp})
            end)

            :noreply

          nil ->
            {:reply, {:not_acceptable, "Invalid SDP"}}
        end
      end
    end
  end
end

defmodule Caracola.Tutorial.Client1 do
  @moduledoc """
  First client of the [tutorial](03-tutorial.md): listens on `127.0.0.1`,
  port 5070 for UDP and TCP and 5071 for TLS.
  """

  use Malla.Service,
    plugins: [Caracola],
    sip: [
      listen: "sip:127.0.0.1:5070, <sip:127.0.0.1:5071;transport=tls>",
      from: "sip:client1@example.com"
    ]

  use Caracola.Tutorial.Client
end

defmodule Caracola.Tutorial.Client2 do
  @moduledoc """
  Second client of the [tutorial](03-tutorial.md): listens on all
  interfaces, random ports, and uses a `sips` From.
  """

  use Malla.Service,
    plugins: [Caracola],
    sip: [
      listen: "sip:all:0, <sip:all:0;transport=tls>",
      from: "sips:client2@example.com"
    ]

  use Caracola.Tutorial.Client
end
