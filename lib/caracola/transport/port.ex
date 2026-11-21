defmodule Caracola.Transport.Port do
  @moduledoc """
  A listener or connection. Equivalent to NkPACKET's `#nkport{}`.

    * `local_ip` / `local_port`: the address of our socket.
    * `remote_ip` / `remote_port`: the peer, `nil` for listeners. For UDP, a
      port with a remote address is the listener socket "connected" to a peer.
    * `listen_ip` / `listen_port`: the listener this port belongs to (the one
      used as base for outgoing connections), to be used in `Via` and
      `Contact` headers.
    * `pid`: the owner process.
    * `handler`: `{module, arg}` receiving the messages, see
      `Caracola.Transport.Handler`.
  """

  @typedoc "A transport protocol of a port."
  @type transport :: :udp | :tcp | :tls | :ws | :wss

  @typedoc "A connection or listening port: transport, local, remote and listen addresses, its process and handler."
  @type t :: %__MODULE__{
          service: term(),
          transport: transport(),
          local_ip: :inet.ip_address() | nil,
          local_port: :inet.port_number() | nil,
          remote_ip: :inet.ip_address() | nil,
          remote_port: :inet.port_number() | nil,
          listen_ip: :inet.ip_address() | nil,
          listen_port: :inet.port_number() | nil,
          pid: pid() | nil,
          socket: term(),
          handler: Caracola.Transport.Handler.t() | nil
        }

  defstruct [
    :service,
    :transport,
    :local_ip,
    :local_port,
    :remote_ip,
    :remote_port,
    :listen_ip,
    :listen_port,
    :pid,
    :socket,
    :handler
  ]
end
