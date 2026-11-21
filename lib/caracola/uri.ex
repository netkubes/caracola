defmodule Caracola.URI do
  @moduledoc """
  SIP URI, optionally in name-addr form (`"Display" <sip:...>;params`).

  Port of NkLIB's `nklib_parse_uri` and `nklib_unparse`. The struct keeps
  both URI-level components (inside `<>`) and header-level ones (outside):

    * `params` / `headers`: URI parameters and headers (`;lr`, `?Route=...`).
    * `ext_params` / `ext_headers`: header parameters after the URI (`;tag=...`).
      When a URI is written without `<>` (addr-spec form), all its parameters
      and headers are header-level ones, as RFC 3261 §20 requires.

  Parameters are `{name, value}` tuples, with `nil` value for flags. Names keep
  their original case; quoted values keep their quotes. URI header names are
  lowercased.

  `port` and `path` are `nil` when absent. `disp` is the raw display name
  (quotes included), or `nil`.
  """

  import Caracola.Util

  @typedoc "A URI scheme."
  @type scheme :: :sip | :sips | :tel | String.t()
  @typedoc "A parameter: name and value (`nil` for flags)."
  @type param :: {String.t(), String.t() | nil}

  @typedoc "A SIP URI, with its parameters and headers."
  @type t :: %__MODULE__{
          scheme: scheme(),
          user: String.t() | nil,
          pass: String.t() | nil,
          domain: String.t(),
          port: :inet.port_number() | nil,
          path: String.t() | nil,
          params: [param()],
          headers: [param()],
          ext_params: [param()],
          ext_headers: [param()],
          disp: String.t() | nil
        }

  defstruct scheme: :sip,
            user: nil,
            pass: nil,
            domain: "",
            port: nil,
            path: nil,
            params: [],
            headers: [],
            ext_params: [],
            ext_headers: [],
            disp: nil

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Parses a comma-separated list of URIs, or a list of such binaries.

      iex> {:ok, [uri]} = Caracola.URI.parse("\\"Bob\\" <sip:bob@example.com:5070;transport=tcp>;tag=1")
      iex> {uri.disp, uri.user, uri.domain, uri.port, uri.params, uri.ext_params}
      {"\\"Bob\\"", "bob", "example.com", 5070, [{"transport", "tcp"}], [{"tag", "1"}]}
  """
  @spec parse(binary() | [binary()]) :: {:ok, [t()]} | :error
  def parse(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case parse(value) do
        {:ok, uris} -> {:cont, {:ok, acc ++ uris}}
        :error -> {:halt, :error}
      end
    end)
  end

  def parse(bin) when is_binary(bin), do: uris(strip(bin), [])

  @doc """
  Parses a single URI. Fails if there is none or more than one.
  """
  @spec parse_one(binary()) :: {:ok, t()} | :error
  def parse_one(bin) do
    case parse(bin) do
      {:ok, [uri]} -> {:ok, uri}
      _ -> :error
    end
  end

  @doc """
  Serializes the URI in name-addr form (always with `<>`), as used in headers.
  """
  @spec encode(t() | [t()]) :: iodata()
  def encode(uris) when is_list(uris), do: Enum.map_intersperse(uris, ", ", &encode/1)

  def encode(%__MODULE__{domain: "*"}), do: "*"

  def encode(%__MODULE__{} = uri) do
    [
      if(uri.disp in [nil, ""], do: [], else: [uri.disp, ?\s]),
      ?<,
      encode_addr(uri),
      uri.path || [],
      encode_params(uri.params),
      encode_headers(uri.headers),
      ?>,
      encode_params(uri.ext_params),
      encode_headers(uri.ext_headers)
    ]
  end

  @doc """
  Serializes the URI as a Request-URI: no `<>`, display name, path, headers
  or header-level parameters.
  """
  @spec encode_ruri(t()) :: iodata()
  def encode_ruri(%__MODULE__{} = uri), do: [encode_addr(uri), encode_params(uri.params)]

  @doc "Gets a URI parameter (inside `<>`), case-insensitively."
  @spec get_param(t(), String.t()) :: {:ok, String.t() | nil} | :error
  def get_param(%__MODULE__{params: params}, name), do: find_param(params, name)

  @doc "Gets a header-level parameter (outside `<>`), case-insensitively."
  @spec get_ext_param(t(), String.t()) :: {:ok, String.t() | nil} | :error
  def get_ext_param(%__MODULE__{ext_params: params}, name), do: find_param(params, name)

  defp encode_addr(uri) do
    [
      scheme_to_string(uri.scheme),
      ?:,
      case uri do
        %{user: user, pass: pass} when user in [nil, ""] and pass in [nil, ""] -> []
        %{user: user, pass: pass} when pass in [nil, ""] -> [user, ?@]
        %{user: user, pass: pass} -> [user, ?:, pass, ?@]
      end,
      uri.domain,
      if(uri.port, do: [?:, Integer.to_string(uri.port)], else: [])
    ]
  end

  defp encode_headers([]), do: []

  defp encode_headers([first | rest]) do
    [?? | Enum.map_intersperse([first | rest], ?&, &encode_header/1)]
  end

  defp encode_header({key, nil}), do: key
  defp encode_header({key, value}), do: [key, ?=, value]

  defp scheme_to_string(scheme) when is_atom(scheme), do: Atom.to_string(scheme)
  defp scheme_to_string(scheme), do: scheme

  ## ===================================================================
  ## Parser (state machine ported from nklib_parse_uri)
  ## ===================================================================

  # `block` is true while we are inside `<...>`

  defp uris(bin, acc) do
    bin = strip(bin)

    case disp(bin, "", false, bin) do
      {:ok, uri, ""} -> {:ok, Enum.reverse([uri | acc])}
      {:ok, uri, rest} -> uris(rest, [uri | acc])
      :error -> :error
    end
  end

  # Display name

  defp disp("", _acc, _quoted, _full), do: :error

  defp disp("*" <> rest, "", false, full) do
    uri = %__MODULE__{domain: "*"}

    case strip(rest) do
      "" -> {:ok, uri, ""}
      <<ch, _::binary>> = rest1 when ch in [?,, ?;] -> opts(rest1, false, uri)
      _ -> disp(rest, "*", false, full)
    end
  end

  defp disp("<" <> rest, acc, false, _full) do
    disp =
      case strip_trailing(acc) do
        "" -> nil
        disp -> disp
      end

    scheme(strip(rest), "", true, %__MODULE__{disp: disp})
  end

  defp disp(":" <> _, _acc, false, full), do: scheme(strip(full), "", false, %__MODULE__{})
  defp disp("," <> _, _acc, false, _full), do: :error

  defp disp(<<?\\, ch, rest::binary>>, acc, true, full),
    do: disp(rest, <<acc::binary, ?\\, ch>>, true, full)

  defp disp(<<?", rest::binary>>, acc, quoted, full),
    do: disp(rest, <<acc::binary, ?">>, not quoted, full)

  defp disp(<<ch, rest::binary>>, acc, quoted, full),
    do: disp(rest, <<acc::binary, ch>>, quoted, full)

  # Scheme

  defp scheme("", _acc, _block, _uri), do: :error
  defp scheme(":" <> _, "", _block, _uri), do: :error

  defp scheme(":" <> rest, acc, block, uri) do
    uri = %{uri | scheme: to_scheme(acc)}
    rest = strip(rest)

    # Try first with a userinfo part, and if it fails, without it
    case user(rest, "", block, uri) do
      {:ok, _, _} = ok -> ok
      :error -> domain(rest, "", false, block, uri)
    end
  end

  defp scheme(<<ch, rest::binary>>, acc, block, uri) when is_ws(ch) do
    case strip(rest) do
      ":" <> _ = rest1 -> scheme(rest1, acc, block, uri)
      _ -> :error
    end
  end

  defp scheme("," <> _, _acc, _block, _uri), do: :error

  defp scheme(<<ch, rest::binary>>, acc, block, uri),
    do: scheme(rest, <<acc::binary, ch>>, block, uri)

  # User

  defp user("", _acc, _block, _uri), do: :error
  defp user(<<ch, _::binary>>, "", _block, _uri) when ch in [?:, ?@], do: :error

  defp user(":" <> rest, acc, block, uri),
    do: pass(strip(rest), "", block, %{uri | user: filter_user(acc)})

  defp user("@" <> rest, acc, block, uri),
    do: domain(strip(rest), "", false, block, %{uri | user: filter_user(acc)})

  defp user(">" <> _, _acc, true, _uri), do: :error

  defp user(<<ch, rest::binary>>, acc, block, uri) when is_ws(ch) do
    case strip(rest) do
      <<ch1, _::binary>> = rest1 when ch1 in [?:, ?@] -> user(rest1, acc, block, uri)
      _ -> :error
    end
  end

  defp user(<<ch, rest::binary>>, acc, block, uri),
    do: user(rest, <<acc::binary, ch>>, block, uri)

  # Password

  defp pass("", _acc, _block, _uri), do: :error
  defp pass("@" <> _, "", _block, _uri), do: :error

  defp pass("@" <> rest, acc, block, uri),
    do: domain(strip(rest), "", false, block, %{uri | pass: acc})

  defp pass(<<ch, rest::binary>>, acc, block, uri) when is_ws(ch) do
    case strip(rest) do
      "@" <> _ = rest1 -> pass(rest1, acc, block, uri)
      _ -> :error
    end
  end

  defp pass(<<ch, rest::binary>>, acc, block, uri),
    do: pass(rest, <<acc::binary, ch>>, block, uri)

  # Domain

  defp domain("", acc, ip6, block, uri) do
    if acc == "" or ip6 or block, do: :error, else: {:ok, %{uri | domain: acc}, ""}
  end

  defp domain("/" <> rest, "", ip6, block, uri), do: domain(rest, "", ip6, block, uri)

  defp domain(<<ch, _::binary>> = rest, acc, ip6, block, uri) when ch in [?;, ??, ?>, ?,, ?/] do
    cond do
      acc == "" or ip6 -> :error
      ch == ?/ -> path(rest, block, %{uri | domain: acc}, "")
      true -> opts(rest, block, %{uri | domain: acc})
    end
  end

  defp domain("[" <> rest, "", false, block, uri), do: domain(rest, "[", true, block, uri)
  defp domain("[" <> _, _acc, _ip6, _block, _uri), do: :error

  defp domain("]" <> rest, acc, true, block, uri) when acc != "",
    do: domain(rest, acc <> "]", false, block, uri)

  defp domain("]" <> _, _acc, _ip6, _block, _uri), do: :error
  defp domain(":" <> _, "", false, _block, _uri), do: :error

  defp domain(":" <> rest, acc, false, block, uri),
    do: port(strip(rest), "", block, %{uri | domain: acc})

  defp domain("@" <> _, _acc, _ip6, _block, _uri), do: :error

  defp domain(<<ch, rest::binary>>, acc, ip6, block, uri) when is_ws(ch) do
    case strip(rest) do
      "" ->
        domain("", acc, ip6, block, uri)

      <<ch1, _::binary>> = rest1 when ch1 in [?:, ?@, ?;, ??, ?>, ?,, ?[, ?]] ->
        domain(rest1, acc, ip6, block, uri)

      _ ->
        :error
    end
  end

  defp domain(<<ch, rest::binary>>, acc, ip6, block, uri),
    do: domain(rest, <<acc::binary, ch>>, ip6, block, uri)

  # Port

  defp port("", acc, block, uri) do
    with false <- block, {:ok, port} <- to_port(acc) do
      {:ok, %{uri | port: port}, ""}
    else
      _ -> :error
    end
  end

  defp port("@" <> _, _acc, _block, _uri), do: :error

  defp port(<<ch, _::binary>> = rest, acc, block, uri) when ch in [?;, ??, ?>, ?,, ?/] do
    case to_port(acc) do
      {:ok, port} when ch == ?/ -> path(rest, block, %{uri | port: port}, "")
      {:ok, port} -> opts(rest, block, %{uri | port: port})
      :error -> :error
    end
  end

  defp port(<<ch, rest::binary>>, acc, block, uri) when is_ws(ch) do
    case strip(rest) do
      "" -> port("", acc, block, uri)
      <<ch1, _::binary>> = rest1 when ch1 in [?@, ?;, ??, ?>, ?,] -> port(rest1, acc, block, uri)
      _ -> :error
    end
  end

  defp port(<<ch, rest::binary>>, acc, block, uri),
    do: port(rest, <<acc::binary, ch>>, block, uri)

  # Parameters and headers

  defp opts("", true, _uri), do: :error
  defp opts("", false, uri), do: {:ok, uri, ""}
  defp opts(";" <> rest, block, uri), do: opts_key(strip(rest), "", block, uri)

  defp opts(<<ch, rest::binary>>, block, uri) when ch in [??, ?&],
    do: headers_key(strip(rest), "", block, uri)

  defp opts(">" <> rest, true, uri), do: opts(strip(rest), false, uri)
  defp opts(">" <> _, false, _uri), do: :error

  defp opts("," <> rest, _block, uri) do
    case strip(rest) do
      "" -> :error
      rest1 -> {:ok, uri, rest1}
    end
  end

  defp opts(<<ch, rest::binary>>, block, uri) when is_ws(ch), do: opts(strip(rest), block, uri)
  defp opts(_, _block, _uri), do: :error

  defp opts_key("", "", _block, _uri), do: :error
  defp opts_key("", acc, block, uri), do: opts("", block, add_param(uri, block, {acc, nil}))
  defp opts_key(<<ch, _::binary>>, "", _block, _uri) when ch in [?;, ??, ?>, ?,, ?=], do: :error

  defp opts_key(<<ch, _::binary>> = rest, acc, block, uri) when ch in [?;, ??, ?>, ?,],
    do: opts(rest, block, add_param(uri, block, {acc, nil}))

  defp opts_key("=" <> rest, acc, block, uri),
    do: opts_value(strip(rest), acc, "", false, block, uri)

  defp opts_key(<<ch, rest::binary>>, acc, block, uri) when is_ws(ch) do
    case strip(rest) do
      "" ->
        opts_key("", acc, block, uri)

      <<ch1, _::binary>> = rest1 when ch1 in [?;, ??, ?>, ?,, ?=] ->
        opts_key(rest1, acc, block, uri)

      _ ->
        :error
    end
  end

  defp opts_key(<<ch, rest::binary>>, acc, block, uri),
    do: opts_key(rest, <<acc::binary, ch>>, block, uri)

  defp opts_value("", key, acc, quoted, block, uri) do
    if acc == "" or quoted, do: :error, else: opts("", block, add_param(uri, block, {key, acc}))
  end

  defp opts_value(<<?\\, ch, rest::binary>>, key, acc, true, block, uri),
    do: opts_value(rest, key, <<acc::binary, ?\\, ch>>, true, block, uri)

  defp opts_value(<<?", rest::binary>>, key, acc, quoted, block, uri),
    do: opts_value(rest, key, <<acc::binary, ?">>, not quoted, block, uri)

  defp opts_value(<<ch, _::binary>> = rest, key, acc, false, block, uri)
       when ch in [?;, ??, ?>, ?,] do
    if acc == "", do: :error, else: opts(rest, block, add_param(uri, block, {key, acc}))
  end

  defp opts_value(<<ch, rest::binary>>, key, acc, false, block, uri) when is_ws(ch) do
    case strip(rest) do
      "" ->
        opts_value("", key, acc, false, block, uri)

      <<ch1, _::binary>> = rest1 when ch1 in [?;, ??, ?>, ?,] ->
        opts_value(rest1, key, acc, false, block, uri)

      _ ->
        :error
    end
  end

  defp opts_value(<<ch, rest::binary>>, key, acc, quoted, block, uri),
    do: opts_value(rest, key, <<acc::binary, ch>>, quoted, block, uri)

  defp headers_key("", "", _block, _uri), do: :error
  defp headers_key("", acc, block, uri), do: opts("", block, add_header(uri, block, {acc, nil}))
  defp headers_key(<<ch, _::binary>>, "", _block, _uri) when ch in [?&, ?>, ?,, ?=], do: :error

  defp headers_key(<<ch, _::binary>> = rest, acc, block, uri) when ch in [?&, ?>, ?,],
    do: opts(rest, block, add_header(uri, block, {acc, nil}))

  defp headers_key("=" <> rest, acc, block, uri),
    do: headers_value(strip(rest), acc, "", false, block, uri)

  defp headers_key(<<ch, rest::binary>>, acc, block, uri) when is_ws(ch) do
    case strip(rest) do
      "" ->
        headers_key("", acc, block, uri)

      <<ch1, _::binary>> = rest1 when ch1 in [?&, ?>, ?,, ?=] ->
        headers_key(rest1, acc, block, uri)

      _ ->
        :error
    end
  end

  defp headers_key(<<ch, rest::binary>>, acc, block, uri) when ch in ?A..?Z,
    do: headers_key(rest, <<acc::binary, ch + 32>>, block, uri)

  defp headers_key(<<ch, rest::binary>>, acc, block, uri),
    do: headers_key(rest, <<acc::binary, ch>>, block, uri)

  defp headers_value("", key, acc, quoted, block, uri) do
    if acc == "" or quoted, do: :error, else: opts("", block, add_header(uri, block, {key, acc}))
  end

  defp headers_value(<<?\\, ch, rest::binary>>, key, acc, true, block, uri),
    do: headers_value(rest, key, <<acc::binary, ?\\, ch>>, true, block, uri)

  defp headers_value(<<?", rest::binary>>, key, acc, quoted, block, uri),
    do: headers_value(rest, key, <<acc::binary, ?">>, not quoted, block, uri)

  defp headers_value(<<ch, _::binary>> = rest, key, acc, false, block, uri)
       when ch in [?&, ?>, ?,] do
    if acc == "", do: :error, else: opts(rest, block, add_header(uri, block, {key, acc}))
  end

  defp headers_value(<<ch, rest::binary>>, key, acc, false, block, uri) when is_ws(ch) do
    case strip(rest) do
      "" ->
        headers_value("", key, acc, false, block, uri)

      <<ch1, _::binary>> = rest1 when ch1 in [?&, ?>, ?,] ->
        headers_value(rest1, key, acc, false, block, uri)

      _ ->
        :error
    end
  end

  defp headers_value(<<ch, rest::binary>>, key, acc, quoted, block, uri),
    do: headers_value(rest, key, <<acc::binary, ch>>, quoted, block, uri)

  # Path (used by ws/wss URIs)

  defp path("", true, _uri, _acc), do: :error
  defp path("", false, uri, acc), do: {:ok, %{uri | path: trim_path(acc)}, ""}

  defp path(<<ch, _::binary>> = rest, block, uri, acc) when ch in [?;, ??, ?>, ?,],
    do: opts(rest, block, %{uri | path: trim_path(acc)})

  defp path(<<ch, rest::binary>>, block, uri, acc),
    do: path(rest, block, uri, <<acc::binary, ch>>)

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp add_param(uri, true, param), do: %{uri | params: uri.params ++ [param]}
  defp add_param(uri, false, param), do: %{uri | ext_params: uri.ext_params ++ [param]}

  defp add_header(uri, true, header), do: %{uri | headers: uri.headers ++ [header]}
  defp add_header(uri, false, header), do: %{uri | ext_headers: uri.ext_headers ++ [header]}

  defp to_scheme(bin) do
    case ascii_downcase(bin) do
      "sip" -> :sip
      "sips" -> :sips
      "tel" -> :tel
      other -> other
    end
  end

  defp to_port(acc) do
    case to_integer(acc) do
      {:ok, port} when port <= 65_535 -> {:ok, port}
      _ -> :error
    end
  end

  # Removes the leading slashes of URLs like http://host
  defp filter_user("//" <> rest), do: rest
  defp filter_user("/" <> rest), do: rest
  defp filter_user(user), do: user

  # Removes a trailing slash, unless the path is just "/"
  defp trim_path("/"), do: "/"

  defp trim_path(path) do
    if String.ends_with?(path, "/"), do: binary_part(path, 0, byte_size(path) - 1), else: path
  end
end

defimpl String.Chars, for: Caracola.URI do
  def to_string(uri), do: uri |> Caracola.URI.encode() |> IO.iodata_to_binary()
end
