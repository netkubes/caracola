defmodule Caracola.EventCompositor.Publication do
  @moduledoc """
  A publication stored by `Caracola.EventCompositor`. Equivalent to NkSIP's
  `#reg_publish{}`: the published `data` (the body of the PUBLISH), its
  `content_type`, the `event` type (lowercase), its `expires` time
  (seconds) and when it was `updated` (monotonic time).
  """

  @typedoc "A stored publication: its body, content type, event, expiration and last update."
  @type t :: %__MODULE__{
          data: binary(),
          content_type: Caracola.Tokens.token() | nil,
          event: String.t() | nil,
          expires: integer(),
          updated: integer() | nil,
          meta: map()
        }

  defstruct [:data, :content_type, :event, :expires, :updated, meta: %{}]
end
