defmodule Caracola.Registrar.Contact do
  @moduledoc """
  A registered contact. Equivalent to NkSIP's `#reg_contact{}`.

    * `index`: identifies the contact for updates (scheme, transport, user,
      host and port).
    * `contact`: the Contact URI, with its `expires` parameter.
    * `updated`: time of the last update (microseconds), `expire`:
      expiration time (seconds).
    * `call_id` and `cseq` of the last REGISTER, to reject old ones.
    * `origin`: `{transport, ip, port}` the REGISTER came from.
    * `path`: the Path of the REGISTER (RFC 3327).
  """

  alias Caracola.URI

  @typedoc "Where a contact was registered from: transport, IP and port."
  @type origin :: {atom(), :inet.ip_address(), :inet.port_number()}

  @typedoc "A registered contact: its URI, expiration, priority (`q`), Call-ID, CSeq and origin."
  @type t :: %__MODULE__{
          index: term(),
          contact: URI.t(),
          updated: integer(),
          expire: integer(),
          q: float(),
          call_id: String.t(),
          cseq: non_neg_integer(),
          origin: origin() | nil,
          path: [URI.t()],
          meta: map()
        }

  defstruct [
    :index,
    :contact,
    :updated,
    :expire,
    :call_id,
    :cseq,
    :origin,
    q: 1.0,
    path: [],
    meta: %{}
  ]
end
