defmodule Caracola.Serializer do
  @moduledoc """
  SIP message serializer. Port of NkSIP's `nksip_unparse`.

  Headers are written in a fixed order (Via, From, To, Call-ID, CSeq,
  Max-Forwards, Content-Length, Route, Contact, Content-Type, Require,
  Supported, Expires, Event), followed by the rest in their original order.
  `Content-Length` is always computed from the body.
  """

  alias Caracola.{Headers, Message, ParseError, Tokens, URI, Via}

  @reasons %{
    100 => "Trying",
    180 => "Ringing",
    181 => "Call Is Being Forwarded",
    182 => "Queued",
    183 => "Session Progress",
    199 => "Early Dialog Terminated",
    200 => "OK",
    202 => "Accepted",
    204 => "No Notification",
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Moved Temporarily",
    305 => "Use Proxy",
    380 => "Alternative Service",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Timeout",
    410 => "Gone",
    412 => "Conditional Request Failed",
    413 => "Request Entity Too Large",
    414 => "Request-URI Too Long",
    415 => "Unsupported Media Type",
    416 => "Unsupported URI Scheme",
    417 => "Unknown Resource Priority",
    420 => "Bad Extension",
    421 => "Extension Required",
    422 => "Session Interval Too Small",
    423 => "Interval Too Brief",
    424 => "Bad Location Information",
    428 => "Use Identity Header",
    429 => "Provide Referrer Identity",
    430 => "Flow Failed",
    433 => "Anonymity Disallowed",
    436 => "Bad Identity-Info",
    437 => "Unsupported Certificate",
    438 => "Invalid Identity Header",
    439 => "First Hop Lacks Outbound Support",
    440 => "Max-Breadth Exceeded",
    469 => "Bad Info Package",
    470 => "Consent Needed",
    480 => "Temporarily Unavailable",
    481 => "Call/Transaction Does Not Exist",
    482 => "Loop Detected",
    483 => "Too Many Hops",
    484 => "Address Incomplete",
    485 => "Ambiguous",
    486 => "Busy Here",
    487 => "Request Terminated",
    488 => "Not Acceptable Here",
    489 => "Bad Event",
    491 => "Request Pending",
    493 => "Undecipherable",
    494 => "Security Agreement Required",
    500 => "Server Internal Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Server Time-out",
    505 => "Version Not Supported",
    513 => "Message Too Large",
    580 => "Precondition Failure",
    600 => "Busy Everywhere",
    603 => "Decline",
    604 => "Does Not Exist Anywhere",
    606 => "Not Acceptable"
  }

  @doc """
  Serializes a message.
  """
  @spec encode(Message.t()) :: binary()
  def encode(%Message{} = msg), do: msg |> to_iodata() |> IO.iodata_to_binary()

  @doc """
  Serializes a message as iodata.
  """
  @spec to_iodata(Message.t()) :: iodata()
  def to_iodata(%Message{class: {:resp, code, reason}} = msg) do
    reason = if reason in [nil, ""], do: reason_phrase(code), else: reason
    ["SIP/2.0 ", Integer.to_string(code), ?\s, reason, "\r\n" | encode_headers_body(msg)]
  end

  def to_iodata(%Message{class: {:req, method}, ruri: ruri} = msg) do
    [
      Message.method_to_string(method),
      ?\s,
      URI.encode_ruri(ruri),
      " SIP/2.0\r\n" | encode_headers_body(msg)
    ]
  end

  @doc """
  Builds the `400 Invalid <header>` response for a request that failed parsing,
  copying the Via, From, To, Call-ID and CSeq headers from the raw request.

  Returns `:error` if the start line could not be parsed or it was a response,
  since then no reply must be sent.
  """
  @spec error_response(ParseError.t()) :: {:ok, binary()} | :error
  def error_response(%ParseError{
        reason: {:invalid, header},
        class: {:req, _, _},
        headers: headers
      }) do
    copied =
      for name <- ~w(via from to call-id cseq),
          {^name, value} <- headers,
          do: [Headers.canonical_name(name), ": ", value, "\r\n"]

    {:ok,
     IO.iodata_to_binary([
       "SIP/2.0 400 Invalid ",
       header,
       "\r\n",
       copied,
       "Content-Length: 0\r\n\r\n"
     ])}
  end

  def error_response(%ParseError{}), do: :error

  @doc """
  Standard reason phrase for a response code.

      iex> Caracola.Serializer.reason_phrase(486)
      "Busy Here"
  """
  @spec reason_phrase(100..699) :: String.t()
  def reason_phrase(code), do: Map.get(@reasons, code, "Unknown Code")

  defp encode_headers_body(%Message{body: body} = msg) do
    {cseq, method} = msg.cseq

    headers =
      Enum.map(msg.vias, &{"via", Via.encode(&1)}) ++
        [
          {"from", URI.encode(msg.from)},
          {"to", URI.encode(msg.to)},
          {"call-id", msg.call_id},
          {"cseq", [Integer.to_string(cseq), ?\s, Message.method_to_string(method)]},
          {"max-forwards", msg.max_forwards && Integer.to_string(msg.max_forwards)},
          {"content-length", Integer.to_string(byte_size(body))}
        ] ++
        Enum.map(msg.routes, &{"route", URI.encode(&1)}) ++
        Enum.map(msg.contacts, &{"contact", URI.encode(&1)}) ++
        [
          {"content-type", msg.content_type && Tokens.encode(msg.content_type)},
          {"require", Enum.join(msg.require, ", ")},
          {"supported", Enum.join(msg.supported, ", ")},
          {"expires", msg.expires && Integer.to_string(msg.expires)},
          {"event", msg.event && Tokens.encode(msg.event)}
        ] ++ msg.headers

    [
      for {name, value} <- headers, value not in [nil, ""] do
        [Headers.canonical_name(name), ": ", value, "\r\n"]
      end,
      "\r\n",
      body
    ]
  end
end

defimpl String.Chars, for: Caracola.Message do
  def to_string(msg), do: Caracola.Serializer.encode(msg)
end
