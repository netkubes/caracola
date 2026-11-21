defmodule Caracola.Digest do
  @moduledoc """
  Digest authentication (RFC 2617, and RFC 7616 and RFC 8760 for the SHA-2
  algorithms), with `qop=auth`. Port of the stateless part of NkSIP's
  `nksip_auth`: parsing of `WWW-Authenticate`, `Proxy-Authenticate`,
  `Authorization` and `Proxy-Authorization` values, generation of challenges
  and credentials, and verification.

  The algorithms are `:md5`, `:sha256` (`SHA-256`) and `:sha512_256`
  (`SHA-512-256`). Nonce generation and tracking is left to the caller.

  Unlike NkSIP, the realm keeps its case (it is part of the HA1 hash) and
  quoted values are unescaped.

  Passwords can be given in clear text or as a precomputed HA1 (the result
  of `ha1/4`), so that clear passwords don't need to be stored:
  `{:ha1, algorithm, hex}`, or `{:ha1, hex}` for MD5. An HA1 is only valid
  for its algorithm.
  """

  import Caracola.Util

  alias Caracola.{Message, URI}

  @typedoc "A quality of protection: `:auth`, `:auth_int` or another token."
  @type qop :: :auth | :auth_int | String.t()

  @typedoc "The parameters of a `WWW-Authenticate`, `Authorization` or similar header, as a map."
  @type params :: %{
          optional(:scheme) => :digest | :basic | String.t(),
          optional(:realm) => String.t(),
          optional(:nonce) => String.t(),
          optional(:opaque) => String.t(),
          optional(:username) => String.t(),
          optional(:uri) => String.t(),
          optional(:response) => String.t(),
          optional(:cnonce) => String.t(),
          optional(:nc) => String.t(),
          optional(:algorithm) => algorithm() | String.t(),
          optional(:qop) => [qop()],
          optional(String.t()) => String.t()
        }

  @typedoc "A digest algorithm: MD5, SHA-256 or SHA-512/256 (RFC 8760)."
  @type algorithm :: :md5 | :sha256 | :sha512_256

  @typedoc "A password: the clear text, or a precomputed `{:ha1, hash}` (optionally with its algorithm)."
  @type password :: String.t() | {:ha1, String.t()} | {:ha1, algorithm(), String.t()}

  @algorithms %{"md5" => :md5, "sha-256" => :sha256, "sha-512-256" => :sha512_256}

  @known ~w(realm nonce opaque username uri response cnonce nc)
  @challenge_headers ["www-authenticate", "proxy-authenticate"]

  ## ===================================================================
  ## Parsing
  ## ===================================================================

  @doc """
  Parses a challenge or credentials header value.

      iex> Caracola.Digest.parse(~S(Digest realm="Example", nonce="abc", qop="auth,auth-int", algorithm=md5))
      {:ok, %{scheme: :digest, realm: "Example", nonce: "abc", qop: [:auth, :auth_int], algorithm: :md5}}
  """
  @spec parse(binary()) :: {:ok, params()} | :error
  def parse(bin) when is_binary(bin) do
    with {:ok, scheme, rest} <- scheme(strip(bin), ""),
         {:ok, params} <- params(strip(rest), %{}) do
      {:ok, Map.put(params, :scheme, scheme)}
    end
  end

  defp scheme(<<ch, rest::binary>>, acc) when is_ws(ch) and acc != "",
    do: {:ok, scheme_name(ascii_downcase(acc)), rest}

  defp scheme(<<ch, rest::binary>>, acc) when not is_ws(ch), do: scheme(rest, <<acc::binary, ch>>)
  defp scheme(_, _), do: :error

  defp scheme_name("digest"), do: :digest
  defp scheme_name("basic"), do: :basic
  defp scheme_name(other), do: other

  defp params(bin, acc) do
    with {:ok, key, rest} <- key(bin, ""),
         {:ok, value, rest} <- value(strip(rest)) do
      acc = put_param(acc, ascii_downcase(key), value)

      case strip(rest) do
        "" -> {:ok, acc}
        "," <> rest -> params(strip(rest), acc)
        _ -> :error
      end
    end
  end

  defp key("=" <> rest, key) when key != "", do: {:ok, key, rest}

  defp key(<<ch, rest::binary>>, key) when is_ws(ch) and key != "" do
    case strip(rest) do
      "=" <> rest -> {:ok, key, rest}
      _ -> :error
    end
  end

  defp key(<<ch, rest::binary>>, key) when ch not in [?=, ?,, ?"] and not is_ws(ch),
    do: key(rest, <<key::binary, ch>>)

  defp key(_, _), do: :error

  defp value(~s(") <> rest), do: quoted(rest, "")
  defp value(bin), do: token(bin, "")

  defp quoted(<<?\\, ch, rest::binary>>, acc), do: quoted(rest, <<acc::binary, ch>>)
  defp quoted(~s(") <> rest, acc), do: {:ok, acc, rest}
  defp quoted(<<ch, rest::binary>>, acc), do: quoted(rest, <<acc::binary, ch>>)
  defp quoted("", _acc), do: :error

  defp token(<<ch, _::binary>>, "") when ch == ?, or is_ws(ch), do: :error
  defp token(<<ch, _::binary>> = rest, acc) when ch == ?, or is_ws(ch), do: {:ok, acc, rest}
  defp token(~s(") <> _, _acc), do: :error
  defp token(<<ch, rest::binary>>, acc), do: token(rest, <<acc::binary, ch>>)
  defp token("", ""), do: :error
  defp token("", acc), do: {:ok, acc, ""}

  defp put_param(acc, key, value) when key in @known, do: Map.put(acc, String.to_atom(key), value)

  defp put_param(acc, "algorithm", value),
    do: Map.put(acc, :algorithm, Map.get(@algorithms, ascii_downcase(value), value))

  defp put_param(acc, "qop", value) do
    qop =
      for token <- String.split(value, [" ", ","], trim: true) do
        case ascii_downcase(token) do
          "auth" -> :auth
          "auth-int" -> :auth_int
          _ -> token
        end
      end

    Map.put(acc, :qop, qop)
  end

  defp put_param(acc, key, value), do: Map.put(acc, key, value)

  @doc """
  Extracts the realms of all the `WWW-Authenticate` and `Proxy-Authenticate`
  headers of a response.
  """
  @spec realms(Message.t() | [{String.t(), String.t()}]) :: [String.t()]
  def realms(%Message{headers: headers}), do: realms(headers)

  def realms(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {name, value} when name in @challenge_headers ->
        case parse(value) do
          {:ok, %{realm: realm}} -> [realm]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  ## ===================================================================
  ## Hashes
  ## ===================================================================

  @doc """
  Calculates the HA1 hash (`H(user:realm:password)`) as lowercase hex, or
  returns the precomputed one (`nil` if it is for another algorithm).

      iex> Caracola.Digest.ha1("user", "pass", "realm")
      "8493fbc53ba582fb4c044c456bdc40eb"
      iex> Caracola.Digest.ha1("Mufasa", "Circle of Life", "http-auth@example.org", :sha256)
      "7987c64c30e25f1b74be53f966b49b90f2808aa92faf9a00262392d7b4794232"
  """
  @spec ha1(String.t(), password(), String.t(), algorithm()) :: String.t() | nil
  def ha1(user, password, realm, algorithm \\ :md5)
  def ha1(_user, {:ha1, ha1}, _realm, :md5), do: ha1
  def ha1(_user, {:ha1, algorithm, ha1}, _realm, algorithm), do: ha1
  def ha1(_user, {:ha1, _}, _realm, _algorithm), do: nil
  def ha1(_user, {:ha1, _, _}, _realm, _algorithm), do: nil
  def ha1(user, password, realm, algorithm), do: hex(algorithm, [user, ?:, realm, ?:, password])

  @doc """
  Calculates the digest `response` value.

  Without `:qop` the RFC 2069 form is used. With `qop: :auth`, the `:cnonce`
  and `:nc` (as sent on the wire, eight hex digits) options are required.
  The `:algorithm` option is `:md5` by default.
  """
  @spec response(Message.method(), String.t(), String.t(), String.t(), keyword()) :: String.t()
  def response(method, uri, ha1, nonce, opts \\ []) do
    algorithm = Keyword.get(opts, :algorithm, :md5)
    ha2 = hex(algorithm, [method_name(method), ?:, uri])

    case Keyword.get(opts, :qop) do
      nil ->
        hex(algorithm, [ha1, ?:, nonce, ?:, ha2])

      :auth ->
        cnonce = Keyword.fetch!(opts, :cnonce)
        nc = Keyword.fetch!(opts, :nc)
        hex(algorithm, [ha1, ?:, nonce, ?:, nc, ?:, cnonce, ":auth:", ha2])
    end
  end

  @doc """
  The strongest algorithm first (RFC 8760 §2.4).

      iex> Caracola.Digest.by_strength([:md5, :sha512_256, :sha256])
      [:sha512_256, :sha256, :md5]
  """
  @spec by_strength([algorithm()]) :: [algorithm()]
  def by_strength(algorithms), do: Enum.sort_by(algorithms, &strength/1, :desc)

  @doc false
  # Unknown algorithms (strings) are the weakest
  def strength(:sha512_256), do: 3
  def strength(:sha256), do: 2
  def strength(:md5), do: 1
  def strength(_other), do: 0

  ## ===================================================================
  ## UAS
  ## ===================================================================

  @doc """
  Generates a `WWW-Authenticate` or `Proxy-Authenticate` value.

      iex> Caracola.Digest.challenge("example.com", "n1", "o1")
      ~S(Digest realm="example.com", nonce="n1", algorithm=MD5, qop="auth", opaque="o1")
      iex> Caracola.Digest.challenge("example.com", "n1", nil, :sha256)
      ~S(Digest realm="example.com", nonce="n1", algorithm=SHA-256, qop="auth")
  """
  @spec challenge(String.t(), String.t(), String.t() | nil, algorithm()) :: String.t()
  def challenge(realm, nonce, opaque \\ nil, algorithm \\ :md5) do
    IO.iodata_to_binary([
      ~s(Digest realm="),
      escape(realm),
      ~s(", nonce="),
      escape(nonce),
      ~s(", algorithm=),
      algorithm_name(algorithm),
      ~s(, qop="auth"),
      if(opaque, do: [~s(, opaque="), escape(opaque), ?"], else: [])
    ])
  end

  @doc """
  Verifies parsed credentials (from `Authorization` or
  `Proxy-Authorization`) for a request with `method` and the user's password.

  Returns `:invalid` if the credentials are not digest with `qop=auth`,
  their algorithm is not in `algorithms` (default `[:md5]`), some field is
  missing, or the password is an HA1 for another algorithm. Checking that the
  nonce was generated by us, and its expiration, is up to the caller.
  """
  @spec verify(params(), Message.method(), password(), [algorithm()]) :: boolean() | :invalid
  def verify(credentials, method, password, algorithms \\ [:md5])

  def verify(%{scheme: :digest, qop: [:auth]} = credentials, method, password, algorithms) do
    algorithm = Map.get(credentials, :algorithm, :md5)

    with true <- algorithm in algorithms,
         %{
           username: user,
           realm: realm,
           nonce: nonce,
           uri: uri,
           cnonce: cnonce,
           nc: nc,
           response: resp
         } <-
           credentials,
         ha1 when is_binary(ha1) <- ha1(user, password, realm, algorithm) do
      opts = [qop: :auth, cnonce: cnonce, nc: nc, algorithm: algorithm]
      expected = response(auth_method(method), uri, ha1, nonce, opts)
      resp = ascii_downcase(resp)
      byte_size(resp) == byte_size(expected) and :crypto.hash_equals(resp, expected)
    else
      _ -> :invalid
    end
  end

  def verify(_credentials, _method, _password, _algorithms), do: :invalid

  ## ===================================================================
  ## UAC
  ## ===================================================================

  @doc """
  Generates an `Authorization` or `Proxy-Authorization` value to answer
  `challenge` (a header value or its parsed form).

  Options:

    * `:method` and `:uri` (binary or `Caracola.URI`) of the request (required).
    * `:user` and `:password` (required).
    * `:cnonce` (random if not given) and `:nc` (integer, default `1`).

  Returns `:error` if the challenge is invalid, uses an unsupported
  algorithm or qop, or the password is an HA1 for another algorithm.
  """
  @spec authorization(binary() | params(), keyword()) :: {:ok, String.t()} | :error
  def authorization(challenge, opts) when is_binary(challenge) do
    with {:ok, params} <- parse(challenge), do: authorization(params, opts)
  end

  def authorization(%{scheme: :digest} = challenge, opts) do
    qop = Map.get(challenge, :qop, [])
    algorithm = Map.get(challenge, :algorithm, :md5)
    password = Keyword.fetch!(opts, :password)
    realm = Map.get(challenge, :realm, "")

    with true <- algorithm in [:md5, :sha256, :sha512_256] and (qop == [] or :auth in qop),
         ha1 when is_binary(ha1) <- ha1(Keyword.fetch!(opts, :user), password, realm, algorithm) do
      {:ok, IO.iodata_to_binary(credentials(challenge, qop != [], ha1, opts))}
    else
      _ -> :error
    end
  end

  def authorization(_challenge, _opts), do: :error

  defp credentials(challenge, qop?, ha1, opts) do
    realm = Map.get(challenge, :realm, "")
    nonce = Map.get(challenge, :nonce, "")
    algorithm = Map.get(challenge, :algorithm, :md5)
    user = Keyword.fetch!(opts, :user)
    uri = request_uri(Keyword.fetch!(opts, :uri))
    method = auth_method(Keyword.fetch!(opts, :method))
    cnonce = Keyword.get_lazy(opts, :cnonce, &new_cnonce/0)

    nc =
      opts
      |> Keyword.get(:nc, 1)
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(8, "0")

    qop_opts = if qop?, do: [qop: :auth, cnonce: cnonce, nc: nc], else: []
    qop_opts = [{:algorithm, algorithm} | qop_opts]

    [
      ~s(Digest username="),
      escape(user),
      ~s(", realm="),
      escape(realm),
      ~s(", nonce="),
      escape(nonce),
      ~s(", uri="),
      escape(uri),
      ~s(", response="),
      response(method, uri, ha1, nonce, qop_opts),
      ~s(", algorithm=),
      algorithm_name(algorithm),
      if(qop?, do: [~s(, qop=auth, cnonce="), escape(cnonce), ~s(", nc=), nc], else: []),
      case challenge do
        %{opaque: opaque} -> [~s(, opaque="), escape(opaque), ?"]
        _ -> []
      end
    ]
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp request_uri(%URI{} = uri), do: IO.iodata_to_binary(URI.encode_ruri(uri))
  defp request_uri(uri) when is_binary(uri), do: uri

  # ACK uses the credentials of the INVITE
  defp auth_method(:ack), do: :invite
  defp auth_method(method), do: method

  defp method_name(method) when is_atom(method), do: Message.method_to_string(method)
  defp method_name(method) when is_binary(method), do: method

  defp new_cnonce, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  # :md5, :sha256 and :sha512_256 are also the names of :crypto
  defp hex(algorithm, data), do: Base.encode16(:crypto.hash(algorithm, data), case: :lower)

  defp algorithm_name(:md5), do: "MD5"
  defp algorithm_name(:sha256), do: "SHA-256"
  defp algorithm_name(:sha512_256), do: "SHA-512-256"

  defp escape(value), do: String.replace(value, ["\\", ~s(")], &("\\" <> &1))
end
