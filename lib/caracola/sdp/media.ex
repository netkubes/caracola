defmodule Caracola.SDP.Media do
  @moduledoc """
  An SDP media description (`m=` section).
  """

  @typedoc "A media description of a session: type, port, protocol, formats and attributes."
  @type t :: %__MODULE__{
          media: String.t(),
          port: :inet.port_number(),
          nports: pos_integer(),
          proto: String.t(),
          fmt: [String.t()],
          info: String.t() | nil,
          connect: Caracola.SDP.address() | nil,
          bandwidth: [String.t()],
          key: String.t() | nil,
          attributes: [Caracola.SDP.attribute()]
        }

  defstruct media: "audio",
            port: 0,
            nports: 1,
            proto: "RTP/AVP",
            fmt: [],
            info: nil,
            connect: nil,
            bandwidth: [],
            key: nil,
            attributes: []
end
