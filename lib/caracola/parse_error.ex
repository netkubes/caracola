defmodule Caracola.ParseError do
  @moduledoc """
  Error returned by `Caracola.Parser.parse/2`.

    * `reason` is `:invalid_message` when the start line or the header block
      cannot be parsed at all, or `{:invalid, header}` when a known header is
      invalid (`header` is its canonical name, like `"Via"` or `"Content-Length"`).
    * `class` and `headers` are the start line and raw headers, if they could be
      parsed. For requests they are enough to build a `400 Invalid <header>`
      response with `Caracola.Serializer.error_response/1`.
  """

  @typedoc "A parse error: the reason, the class of the message when it could be read, and the headers needed to answer it."
  @type t :: %__MODULE__{
          reason: :invalid_message | {:invalid, String.t()},
          class:
            {:req, Caracola.Message.method(), String.t()} | {:resp, String.t(), String.t()} | nil,
          headers: [{String.t(), String.t()}]
        }

  defexception reason: :invalid_message, class: nil, headers: []

  @impl true
  def message(%__MODULE__{reason: :invalid_message}), do: "invalid SIP message"
  def message(%__MODULE__{reason: {:invalid, header}}), do: "invalid #{header} header"
end
