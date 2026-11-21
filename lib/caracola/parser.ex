defmodule Caracola.Parser do
  @moduledoc """
  SIP message parser. Port of NkSIP's `nksip_parse_sipmsg` and `nksip_parse`.

  `parse/2` frames the message using `Content-Length` and parses it into a
  `Caracola.Message`:

    * On stream transports (`:tcp`, `:tls`) `Content-Length` is mandatory and
      `:partial` is returned while the message is incomplete.
    * On message transports (`:udp`, `:sctp`, `:ws`, `:wss`) a missing
      `Content-Length` means that the body is the rest of the packet.
    * Any bytes after the message are returned as `rest`.

  Known headers are validated in the same order as NkSIP, so the reason of a
  `400 Invalid <header>` response is the same.
  """

  import Caracola.Util

  alias Caracola.{Headers, Message, ParseError, Tokens, URI, Via}

  @stream_transports [:tcp, :tls]

  @parsed_headers ~w(from to call-id via cseq max-forwards route contact expires
                     require supported event content-type content-length)

  @typedoc "The result of parsing: a message and the rest of the data, `:partial` if more data is needed, or an error."
  @type result ::
          {:ok, Message.t(), rest :: binary()}
          | :partial
          | {:error, ParseError.t()}

  @doc """
  Parses a SIP message received over `transport`.
  """
  @spec parse(binary(), Via.transport()) :: result()
  def parse(bin, transport \\ :udp) do
    bin = skip_crlf(bin)
    stream? = transport in @stream_transports

    case :binary.match(bin, "\r\n\r\n") do
      :nomatch when stream? ->
        :partial

      :nomatch ->
        {:error, %ParseError{}}

      {pos, 4} ->
        head = binary_part(bin, 0, pos)
        rest = binary_part(bin, pos + 4, byte_size(bin) - pos - 4)
        [first | lines] = :binary.split(head, "\r\n", [:global])

        with {:ok, class} <- start_line(first),
             {:ok, headers} <- header_lines(lines) do
          frame(class, headers, rest, stream?)
        else
          :error -> {:error, %ParseError{}}
        end
    end
  end

  @doc """
  Same as `parse/2` but raises `Caracola.ParseError` on errors.
  """
  @spec parse!(binary(), Via.transport()) :: {Message.t(), binary()} | :partial
  def parse!(bin, transport \\ :udp) do
    case parse(bin, transport) do
      {:ok, msg, rest} -> {msg, rest}
      :partial -> :partial
      {:error, error} -> raise error
    end
  end

  ## ===================================================================
  ## Framing
  ## ===================================================================

  # RFC 3261 §7.5: CRLFs before the start line should be ignored
  defp skip_crlf("\r\n" <> rest), do: skip_crlf(rest)
  defp skip_crlf(bin), do: bin

  defp start_line("SIP/2.0 " <> rest) do
    case :binary.split(rest, " ") do
      [""] -> :error
      ["" | _] -> :error
      [code] -> {:ok, {:resp, code, ""}}
      [code, reason] -> {:ok, {:resp, code, reason}}
    end
  end

  defp start_line(line) do
    case :binary.split(line, " ", [:global]) do
      [method, uri, "SIP/2.0"] when method != "" and uri != "" ->
        {:ok, {:req, Message.to_method(method), uri}}

      _ ->
        :error
    end
  end

  defp header_lines(lines) do
    lines
    |> Enum.reduce_while([], fn
      <<ch, _::binary>> = line, [{name, value} | acc] when ch in [?\s, ?\t] ->
        {:cont, [{name, value <> " " <> trim(line)} | acc]}

      line, acc ->
        case header_line(line) do
          {:ok, header} -> {:cont, [header | acc]}
          :error -> {:halt, :error}
        end
    end)
    |> case do
      :error -> :error
      headers -> {:ok, headers |> Enum.reverse() |> Enum.map(fn {n, v} -> {n, trim(v)} end)}
    end
  end

  defp header_line(line) do
    with [name, value] <- :binary.split(line, ":"),
         name = strip_trailing(name),
         true <- valid_name?(name) do
      {:ok, {Headers.normalize_name(name), value}}
    else
      _ -> :error
    end
  end

  defp valid_name?(""), do: false
  defp valid_name?(name), do: not String.contains?(name, [" ", "\t"])

  defp frame(class, headers, rest, stream?) do
    case content_length(headers, stream?) do
      nil ->
        build(class, headers, rest, "")

      len when byte_size(rest) == len ->
        build(class, headers, rest, "")

      len when byte_size(rest) > len ->
        <<body::binary-size(^len), tail::binary>> = rest
        build(class, headers, body, tail)

      len when is_integer(len) and stream? ->
        :partial

      _ ->
        invalid(class, headers, "Content-Length")
    end
  end

  # Returns nil if there is no Content-Length (allowed only on message
  # transports) or :error if it is invalid
  defp content_length(headers, stream?) do
    case values(headers, "content-length") do
      [] when stream? -> :error
      [] -> nil
      [value] -> with {:ok, len} <- to_integer(value), do: len
      _ -> :error
    end
  end

  defp build(class, headers, body, tail) do
    case message(class, headers, body) do
      {:ok, msg} -> {:ok, msg, tail}
      {:invalid, name} -> invalid(class, headers, name)
    end
  end

  defp invalid(class, headers, name),
    do: {:error, %ParseError{reason: {:invalid, name}, class: class, headers: headers}}

  ## ===================================================================
  ## Message
  ## ===================================================================

  defp message(class, headers, body) do
    with {:ok, call_id} <- call_id(headers),
         {:ok, class, ruri} <- class(class),
         {:ok, from} <- single_uri(headers, "from", "From"),
         {:ok, to} <- single_uri(headers, "to", "To"),
         {:ok, vias} <- vias(headers),
         {:ok, cseq} <- cseq(headers, class),
         {:ok, max_forwards} <- integer(headers, "max-forwards", "Max-Forwards", 0..299),
         {:ok, routes} <- uris(headers, "route", "Route"),
         {:ok, contacts} <- uris(headers, "contact", "Contact"),
         {:ok, expires} <- integer(headers, "expires", "Expires", 0..0xFFFFFFFF),
         {:ok, content_type} <- single_token(headers, "content-type", "Content-Type", false),
         {:ok, require} <- token_names(headers, "require", "Require"),
         {:ok, supported} <- token_names(headers, "supported", "Supported"),
         {:ok, event} <- single_token(headers, "event", "Event", event_required?(class)) do
      {:ok,
       %Message{
         class: class,
         ruri: ruri,
         vias: vias,
         from: from,
         from_tag: tag(from),
         to: to,
         to_tag: tag(to),
         call_id: call_id,
         cseq: cseq,
         max_forwards: max_forwards,
         routes: routes,
         contacts: contacts,
         content_type: content_type,
         require: require,
         supported: supported,
         expires: expires,
         event: event,
         headers: Enum.reject(headers, fn {name, _} -> name in @parsed_headers end),
         body: body
       }}
    end
  end

  # Like NkSIP, only the first Call-ID is used
  defp call_id(headers) do
    case values(headers, "call-id") do
      [call_id | _] when call_id != "" -> {:ok, call_id}
      _ -> {:invalid, "Call-ID"}
    end
  end

  defp class({:req, method, ruri}) do
    case URI.parse("<" <> ruri <> ">") do
      {:ok, [ruri]} -> {:ok, {:req, method}, ruri}
      _ -> {:invalid, "Request-URI"}
    end
  end

  defp class({:resp, code, reason}) do
    case to_integer(code) do
      {:ok, code} when code in 100..699 -> {:ok, {:resp, code, reason}, nil}
      _ -> {:invalid, "Code"}
    end
  end

  defp single_uri(headers, name, invalid) do
    case URI.parse(values(headers, name)) do
      {:ok, [uri]} -> {:ok, uri}
      _ -> {:invalid, invalid}
    end
  end

  defp uris(headers, name, invalid) do
    case URI.parse(values(headers, name)) do
      {:ok, uris} -> {:ok, uris}
      :error -> {:invalid, invalid}
    end
  end

  defp vias(headers) do
    case Via.parse(values(headers, "via")) do
      {:ok, [_ | _] = vias} -> {:ok, vias}
      _ -> {:invalid, "Via"}
    end
  end

  defp cseq(headers, class) do
    with [value] <- values(headers, "cseq"),
         [num, method] <- String.split(value, [" ", "\t"], trim: true),
         method = Message.to_method(method),
         true <- cseq_method?(class, method),
         {:ok, num} when num < 0x100000000 <- to_integer(num) do
      {:ok, {num, method}}
    else
      _ -> {:invalid, "CSeq"}
    end
  end

  defp cseq_method?({:req, method}, method), do: true
  defp cseq_method?({:req, _}, _), do: false
  defp cseq_method?({:resp, _, _}, _), do: true

  defp integer(headers, name, invalid, range) do
    with [value] <- values(headers, name),
         {:ok, int} <- to_integer(value),
         true <- int in range do
      {:ok, int}
    else
      [] -> {:ok, nil}
      _ -> {:invalid, invalid}
    end
  end

  defp single_token(headers, name, invalid, required?) do
    case Tokens.parse(values(headers, name)) do
      {:ok, []} when not required? -> {:ok, nil}
      {:ok, [token]} -> {:ok, token}
      _ -> {:invalid, invalid}
    end
  end

  defp token_names(headers, name, invalid) do
    case Tokens.parse(values(headers, name)) do
      {:ok, tokens} -> {:ok, for({name, _} <- tokens, do: name)}
      :error -> {:invalid, invalid}
    end
  end

  defp event_required?({:req, method}), do: method in [:subscribe, :notify]
  defp event_required?(_), do: false

  defp tag(uri) do
    case URI.get_ext_param(uri, "tag") do
      {:ok, tag} -> tag
      :error -> nil
    end
  end

  defp values(headers, name), do: for({^name, value} <- headers, do: value)
end
