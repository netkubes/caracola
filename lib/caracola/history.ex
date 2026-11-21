defmodule Caracola.History do
  @moduledoc """
  Call history: the `History-Info` (RFC 7044) and `Diversion` (RFC 5806)
  headers, that tell the final destination of a request (a voicemail, a
  forwarded phone...) the targets it went through, and why it was
  retargeted.

  Proxies retarget requests with `retarget/3`, a `sip_route/5` result:

  ```
  defcb sip_route(_scheme, "alice", "example.com", req, _call) do
    if MyApp.forwarding?("alice"),
      do: Caracola.History.retarget(req, ["sip:voicemail@example.com"], cause: 302),
      else: :proxy
  end
  ```

  Each destination gets a new History-Info entry, child of the one of the
  current Request-URI (which is added first if the request has none), and
  the `cause` (RFC 4458) is added to its URI. With `:diversion`, a
  Diversion header is added too, for the equipment that only understands
  it.

  `entries/1` and `diversions/1` read the headers of a received request.
  """

  alias Caracola.{Message, URI}

  @typedoc """
  A History-Info entry: the URI (with its `cause` param and the `Reason`
  header, if any), its index (as `"1.1.2"`), and how it was retargeted
  from its parent: `:rc` (to a registered contact), `:mp` (mapped to
  another user) or `:np` (not changed), with the index of the parent.
  """
  @type entry :: %{
          uri: URI.t(),
          index: String.t() | nil,
          type: {:rc | :mp | :np, String.t()} | nil,
          cause: non_neg_integer() | nil,
          reason: String.t() | nil
        }

  @typedoc "A Diversion: the diverted URI, the reason and the counter."
  @type diversion :: %{uri: URI.t(), reason: String.t() | nil, counter: pos_integer()}

  @reasons %{
    302 => "unconditional",
    404 => "unavailable",
    408 => "no-answer",
    480 => "deflection",
    486 => "user-busy",
    487 => "deflection",
    503 => "out-of-service"
  }

  @doc """
  A `sip_route/5` result proxying `req` to `targets` (URIs, tried in
  parallel), with a History-Info entry for each of them.

  Options:

    * `{:cause, code}` - the reason of the retargeting (RFC 4458): 302
      (unconditional forwarding), 486 (busy), 408 (no answer), 404
      (unknown or not available), 480 or 487 (deflection) and 503 (not
      reachable). It is added as `cause` param to the targets.
    * `{:type, :mp | :rc}` - `:mp` (the default) when the target is another
      user, `:rc` for the registered contacts of the same one.
    * `:diversion` or `{:diversion, reason}` - add a Diversion header with
      the current Request-URI, and the reason (by default, the one of the
      cause).
    * `{:proxy_opts, opts}` - options of the proxy.

  ```
  iex> {:ok, req, ""} = Caracola.Parser.parse("INVITE sip:alice@example.com SIP/2.0\\r\\nVia: SIP/2.0/UDP h;branch=z9hG4bKa\\r\\nFrom: <sip:a@h>;tag=1\\r\\nTo: <sip:alice@example.com>\\r\\nCall-ID: c\\r\\nCSeq: 1 INVITE\\r\\n\\r\\n")
  iex> {:proxy, [target], []} = Caracola.History.retarget(req, ["sip:vm@example.com"], cause: 302)
  iex> for {"History-Info", value} <- target.headers, do: URI.decode_www_form(value)
  ["<sip:alice@example.com>;index=1", "<sip:vm@example.com;cause=302>;index=1.1;mp=1"]
  ```
  """
  @spec retarget(Message.t(), [String.t() | URI.t()], list()) :: {:proxy, [URI.t()], list()}
  def retarget(%Message{} = req, targets, opts \\ []) do
    cause = opt(opts, :cause)
    type = opt(opts, :type) || :mp
    entries = entries(req)

    # The entry of the current Request-URI: the last one, or a new one
    {parent, initial} =
      case List.last(entries) do
        %{index: index} when is_binary(index) -> {index, []}
        _ -> {"1", [encode(req.ruri, [{"index", "1"}])]}
      end

    first = 1 + Enum.count(entries, &child?(&1.index, parent))

    targets =
      targets
      |> Enum.map(&parse!/1)
      |> Enum.with_index(first)
      |> Enum.map(fn {uri, n} ->
        uri = if cause, do: put_param(uri, "cause", Integer.to_string(cause)), else: uri
        entry = encode(uri, [{"index", "#{parent}.#{n}"}, {Atom.to_string(type), parent}])

        headers =
          for value <- initial ++ [entry], do: {"History-Info", Elixir.URI.encode_www_form(value)}

        %{uri | headers: uri.headers ++ headers}
      end)

    {:proxy, targets, diversion(req, cause, opts) ++ (opt(opts, :proxy_opts) || [])}
  end

  @doc "The History-Info entries of a message, in order."
  @spec entries(Message.t()) :: [entry()]
  def entries(%Message{} = msg) do
    for uri <- uris(msg, "history-info") do
      %{
        uri: %{uri | ext_params: []},
        index: param(uri, "index"),
        type: type(uri),
        cause: cause(uri),
        reason: reason(uri)
      }
    end
  end

  @doc "The Diversion headers of a message, the most recent first."
  @spec diversions(Message.t()) :: [diversion()]
  def diversions(%Message{} = msg) do
    for uri <- uris(msg, "diversion") do
      counter =
        case Integer.parse(param(uri, "counter") || "1") do
          {counter, ""} -> counter
          _ -> 1
        end

      %{uri: %{uri | ext_params: []}, reason: param(uri, "reason"), counter: counter}
    end
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp diversion(req, cause, opts) do
    reason =
      case opt(opts, :diversion) do
        nil -> if :diversion in opts, do: Map.get(@reasons, cause, "unknown")
        reason -> reason
      end

    if reason do
      uri = %{req.ruri | params: [], headers: []}
      [{:insert, "diversion", encode(uri, [{"reason", reason}, {"counter", "1"}])}]
    else
      []
    end
  end

  defp cause(uri) do
    case Integer.parse(param_uri(uri, "cause") || "") do
      {code, ""} -> code
      _ -> nil
    end
  end

  # The Reason header in the URI of an entry
  defp reason(uri) do
    Enum.find_value(uri.headers, fn {name, value} ->
      if String.downcase(name) == "reason", do: Elixir.URI.decode(value || "")
    end)
  end

  # How an entry was retargeted, and its parent
  defp type(uri) do
    Enum.find_value([:rc, :mp, :np], fn type ->
      if parent = param(uri, Atom.to_string(type)), do: {type, parent}
    end)
  end

  defp child?(index, parent) when is_binary(index) do
    case String.split_at(index, byte_size(parent) + 1) do
      {prefix, rest} -> prefix == parent <> "." and rest != "" and not String.contains?(rest, ".")
    end
  end

  defp child?(_index, _parent), do: false

  defp uris(msg, name) do
    for value <- Message.header(msg, name),
        {:ok, uris} <- [URI.parse(value)],
        uri <- uris,
        do: uri
  end

  defp parse!(%URI{} = uri), do: uri

  defp parse!(uri) when is_binary(uri) do
    {:ok, uri} = URI.parse_one(uri)
    uri
  end

  defp encode(uri, ext_params),
    do: IO.iodata_to_binary(URI.encode(%{uri | headers: [], ext_params: ext_params}))

  defp put_param(uri, name, value),
    do: %{uri | params: List.keystore(uri.params, name, 0, {name, value})}

  defp param(uri, name) do
    case List.keyfind(uri.ext_params, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp param_uri(uri, name) do
    case List.keyfind(uri.params, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp opt(opts, key) do
    Enum.find_value(opts, fn
      {^key, value} -> value
      _ -> nil
    end)
  end
end
