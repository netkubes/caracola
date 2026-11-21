defmodule Caracola.StirShaken do
  @moduledoc """
  Caller identity signing and verification with STIR/SHAKEN: the
  `Identity` header (RFC 8224) with a PASSporT (RFC 8225) and the SHAKEN
  extension (RFC 8588), signed with ES256.

  ```
  defmodule MyProxy do
    use Malla.Service,
      plugins: [Caracola.StirShaken],
      sip: [listen: "sip:all:5060"],
      stir_shaken: [
        key: File.read!("priv/shaken_key.pem"),
        x5u: "https://cert.example.com/shaken.pem",
        verify: [trusted: [File.read!("priv/sti_ca.pem")], enforce: :invalid]
      ]
  end
  ```

  ## Signing (authentication service)

  The service signs the calls it originates or proxies, with the `:key`
  (an EC P-256 private key, in PEM) whose certificate is published at the
  `:x5u` URL. The application decides the attestation level (`"A"`, `"B"`
  or `"C"`, RFC 8588 §4) and adds the header with `sign_opts/3`:

  ```
  defcb sip_route(_scheme, _user, _domain, req, call) do
    {:proxy, :ruri, Caracola.StirShaken.sign_opts(call.service, req, attest: "A")}
  end
  ```

  The originating number is the one of the P-Asserted-Identity, if any,
  or the From; the destination is the one of the To. `identity/4` builds
  the header for other numbers.

  ## Verification (verification service)

  `verify/2` checks the `Identity` header of a request (RFC 8224 §6.2):

    * its PASSporT is well formed and uses ES256 (438 and 437 otherwise),
    * it is fresh: its `iat` is less than `:max_age` seconds old (403
      Stale Date otherwise),
    * its originating and destination numbers are the ones of the request
      (438 otherwise),
    * the certificate of its `x5u` (or `info`) URL can be fetched, is valid
      and chains to one of the `:trusted` certificates, and the PASSporT is
      signed with its key (436 or 438 otherwise).

  Certificates are cached for `:cache_time` milliseconds. They are fetched
  over HTTPS by `sip_stir_shaken_fetch/2`, which services can implement to
  fetch them otherwise. Without `:trusted` certificates the chain is not
  checked, which is only acceptable for tests.

  With `enforce: :invalid` (or `:all`), initial INVITEs are verified
  before they are routed, and rejected if the verification fails (and, with
  `:all`, if they have no Identity: 428). Otherwise, the application calls
  `verify/2` and decides, for example, the `verstat` to pass on.

  Numbers are compared in canonical form (RFC 8224 §8.3): the user part of
  SIP URIs (or the number of tel URIs) without `+` nor visual separators.
  Only telephone numbers are supported, and PASSporTs in compact form
  (without claims) are rejected.

  ## Configuration

  Under the `:stir_shaken` key:

    * `:key` - EC P-256 private key to sign with, in PEM.
    * `:x5u` - URL of the certificate of the key.
    * `:attest` - default attestation level (default `"C"`).
    * `:verify` - verification options:
      * `:trusted` - trusted CA certificates, in PEM (default `[]`).
      * `:max_age` - maximum age of a PASSporT, in seconds (default 60).
      * `:cache_time` - milliseconds to cache certificates (default
        3600000).
      * `:enforce` - `false` (default), `:invalid` or `:all`.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  require Logger
  require Record

  alias Caracola.{Message, URI}
  alias Caracola.StirShaken.{Certs, Passport}

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(:otp_cert, :OTPCertificate, Record.extract(:OTPCertificate, from_lib: @hrl))

  Record.defrecordp(
    :otp_tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: @hrl)
  )

  Record.defrecordp(
    :otp_spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: @hrl)
  )

  Record.defrecordp(
    :pk_alg,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: @hrl)
  )

  @verify_schema NimbleOptions.new!(
                   trusted: [type: {:list, :string}, default: []],
                   max_age: [type: :pos_integer, default: 60],
                   cache_time: [type: :pos_integer, default: 3_600_000],
                   enforce: [type: {:in, [false, :invalid, :all]}, default: false]
                 )

  @schema NimbleOptions.new!(
            key: [type: :string],
            x5u: [type: :string],
            attest: [type: {:in, ["A", "B", "C"]}, default: "C"],
            verify: [type: :keyword_list, default: []]
          )

  @typedoc ~s{An attestation level: `"A"` (full), `"B"` (partial) or `"C"` (gateway).}
  @type attest :: String.t()
  @typedoc "Why an Identity header failed verification."
  @type error ::
          :no_identity
          | :invalid_identity_header
          | :unsupported_credential
          | :stale_date
          | :bad_identity_info
  @typedoc "The claims of a PASSporT that verified correctly."
  @type verified :: %{
          attest: attest() | nil,
          orig: String.t(),
          dest: [String.t()],
          iat: integer(),
          origid: String.t() | nil,
          x5u: String.t()
        }

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Request or proxy options adding an Identity header to a request, signed
  by the service. The originating number is the one of the
  P-Asserted-Identity or the From of `req`, and the destination the one of
  its To. Options are the ones of `identity/4`.
  """
  @spec sign_opts(module(), Message.t(), keyword()) :: list()
  def sign_opts(service, %Message{} = req, opts \\ []) do
    case {orig(req), tn(req.to)} do
      {orig, dest} when is_binary(orig) and is_binary(dest) ->
        [{:add, "identity", identity(service, orig, [dest], opts)}]

      _ ->
        Logger.warning("STIR/SHAKEN: no telephone numbers to sign", call_id: req.call_id)
        []
    end
  end

  @doc """
  The value of an Identity header signed by the service, for an
  originating number and the destination numbers.

  Options:

    * `:attest` - attestation level, `"A"`, `"B"` or `"C"` (the
      `:attest` of the configuration by default).
    * `:origid` - origination identifier (a new UUID by default).
    * `:iat` - issue time, in seconds since the epoch (now by default).
  """
  @spec identity(module(), String.t(), [String.t()], keyword()) :: String.t()
  def identity(service, orig, dest, opts \\ []) do
    config = config(service)
    key = config[:key] || raise ArgumentError, "no STIR/SHAKEN key in #{inspect(service)}"
    x5u = config[:x5u]

    claims = %{
      "attest" => Keyword.get(opts, :attest, config[:attest]),
      "dest" => %{"tn" => Enum.map(dest, &canonical/1)},
      "iat" => Keyword.get_lazy(opts, :iat, fn -> System.os_time(:second) end),
      "orig" => %{"tn" => canonical(orig)},
      "origid" => Keyword.get_lazy(opts, :origid, &uuid/0)
    }

    token = Passport.encode(%{"ppt" => "shaken", "x5u" => x5u}, claims, key)
    "#{token};info=<#{x5u}>;alg=ES256;ppt=shaken"
  end

  @doc """
  Verifies the Identity header of a request. Returns the verified claims,
  or the reason of the failure (see `reply/1`).
  """
  @spec verify(module(), Message.t()) :: {:ok, verified()} | {:error, error()}
  def verify(service, %Message{} = req) do
    config = Keyword.get(config(service), :verify, [])

    with {:ok, value} <- identity_header(req),
         {:ok, token, info} <- parse_identity(value),
         {:ok, passport} <- decode(token),
         {:ok, x5u} <- x5u(passport, info),
         :ok <- check_fresh(passport.claims, config[:max_age]),
         :ok <- check_numbers(passport.claims, req),
         {:ok, public_key} <- public_key(service, x5u, config),
         :ok <- check_signature(passport, public_key) do
      claims = passport.claims

      {:ok,
       %{
         attest: claims["attest"],
         orig: get_in(claims, ["orig", "tn"]),
         dest: List.wrap(get_in(claims, ["dest", "tn"])),
         iat: claims["iat"],
         origid: claims["origid"],
         x5u: x5u
       }}
    end
  end

  @doc """
  The reply for a verification failure (RFC 8224 §6.2.2).

      iex> Caracola.StirShaken.reply(:stale_date)
      {403, [reason_phrase: "Stale Date"]}
  """
  @spec reply(error()) :: Caracola.Reply.sipreply()
  def reply(:no_identity), do: {428, reason_phrase: "Use Identity Header"}
  def reply(:stale_date), do: {403, reason_phrase: "Stale Date"}
  def reply(:bad_identity_info), do: {436, reason_phrase: "Bad Identity Info"}
  def reply(:unsupported_credential), do: {437, reason_phrase: "Unsupported Credential"}
  def reply(:invalid_identity_header), do: {438, reason_phrase: "Invalid Identity Header"}

  @doc """
  Canonical form of a telephone number (RFC 8224 §8.3): without `+` nor
  visual separators. `nil` if it is not a number.

      iex> Caracola.StirShaken.canonical("+1 (555) 123-4567")
      "15551234567"
      iex> Caracola.StirShaken.canonical("alice")
      nil
  """
  @spec canonical(String.t() | nil) :: String.t() | nil
  def canonical(nil), do: nil

  def canonical(number) do
    digits = String.replace(number, ["+", "-", ".", "(", ")", " "], "")
    if digits != "" and String.match?(digits, ~r/^[0-9]+$/), do: digits
  end

  @doc "Removes the cached certificates of a service."
  @spec clear_cache(module()) :: :ok
  def clear_cache(service), do: Certs.clear(service)

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <- NimbleOptions.validate(Keyword.get(config, :stir_shaken, []), @schema),
         {:ok, verify} <- NimbleOptions.validate(opts[:verify], @verify_schema),
         {:ok, key} <- private_key(opts[:key]),
         {:ok, trusted} <- trusted(verify[:trusted]) do
      verify = Keyword.put(verify, :trusted, trusted)
      opts = opts |> Keyword.put(:key, key) |> Keyword.put(:verify, verify)
      {:ok, Keyword.put(config, :stir_shaken, opts)}
    end
  end

  @doc false
  # Fetches the certificate (a PEM, possibly with the chain) at a URL
  defcb sip_stir_shaken_fetch(url, _service), do: fetch(url)

  # Initial INVITEs are verified before routing, with :enforce
  defcb caracola_callback(
          :sip_route,
          [_, _, _, %Message{class: {:req, :invite}, to_tag: nil} = req, call]
        ) do
    case get_in(config(call.service), [:verify, :enforce]) do
      enforce when enforce in [:invalid, :all] ->
        case verify(call.service, req) do
          {:ok, _} -> :cont
          {:error, :no_identity} when enforce == :invalid -> :cont
          {:error, reason} -> {:done, {:reply, reply(reason)}}
        end

      _ ->
        :cont
    end
  end

  def caracola_callback(_fun, _args), do: :cont

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp config(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> Keyword.get(config, :stir_shaken, [])
      _ -> []
    end
  end

  defp private_key(nil), do: {:ok, nil}

  defp private_key(pem) do
    case for({:ECPrivateKey, _, _} = entry <- :public_key.pem_decode(pem), do: entry) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, :invalid_stir_shaken_key}
    end
  rescue
    _ -> {:error, :invalid_stir_shaken_key}
  end

  defp trusted(pems) do
    ders = for pem <- pems, {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
    if length(ders) >= length(pems), do: {:ok, ders}, else: {:error, :invalid_trusted_cert}
  rescue
    _ -> {:error, :invalid_trusted_cert}
  end

  defp orig(req) do
    pai =
      for value <- Message.header(req, "p-asserted-identity"),
          {:ok, uris} <- [URI.parse(value)],
          uri <- uris,
          tn = tn(uri),
          tn != nil,
          do: tn

    List.first(pai) || tn(req.from)
  end

  defp tn(%URI{scheme: :tel, domain: number}), do: canonical(number)
  defp tn(%URI{user: user}), do: canonical(user)
  defp tn(_), do: nil

  defp identity_header(req) do
    case Message.header(req, "identity") do
      [value | _] -> {:ok, value}
      [] -> {:error, :no_identity}
    end
  end

  # "token;info=<url>;alg=ES256;ppt=shaken"
  defp parse_identity(value) do
    [token | params] = String.split(String.trim(value), ";")

    params =
      for param <- params,
          [name, val] <- [String.split(param, "=", parts: 2)],
          do: {String.downcase(String.trim(name)), String.trim(val)}

    case List.keyfind(params, "alg", 0) do
      {_, alg} when alg != "ES256" -> {:error, :unsupported_credential}
      _ -> {:ok, String.trim(token), info(params)}
    end
  end

  defp info(params) do
    case List.keyfind(params, "info", 0) do
      {_, "<" <> rest} -> String.trim_trailing(rest, ">")
      {_, url} -> url
      nil -> nil
    end
  end

  defp decode(token) do
    case Passport.decode(token) do
      {:ok, %{header: %{"alg" => "ES256"}} = passport} -> {:ok, passport}
      {:ok, _} -> {:error, :unsupported_credential}
      :error -> {:error, :invalid_identity_header}
    end
  end

  defp x5u(%{header: header}, info) do
    case header["x5u"] || info do
      url when is_binary(url) -> {:ok, url}
      _ -> {:error, :bad_identity_info}
    end
  end

  defp check_fresh(%{"iat" => iat}, max_age) when is_integer(iat) do
    if abs(System.os_time(:second) - iat) <= max_age, do: :ok, else: {:error, :stale_date}
  end

  defp check_fresh(_claims, _max_age), do: {:error, :invalid_identity_header}

  defp check_numbers(claims, req) do
    dest = List.wrap(get_in(claims, ["dest", "tn"]))

    if get_in(claims, ["orig", "tn"]) == orig(req) and tn(req.to) in dest,
      do: :ok,
      else: {:error, :invalid_identity_header}
  end

  defp check_signature(passport, public_key) do
    if Passport.verify(passport, public_key), do: :ok, else: {:error, :invalid_identity_header}
  end

  defp public_key(service, url, config) do
    with :error <- Certs.get(service, url),
         {:ok, pem} <- service.sip_stir_shaken_fetch(url, service),
         {:ok, key} <- validate_chain(pem, config[:trusted]) do
      Certs.put(service, url, key, config[:cache_time])
      {:ok, key}
    else
      {:ok, key} ->
        {:ok, key}

      {:error, reason} ->
        Logger.notice("STIR/SHAKEN certificate #{url} rejected: #{inspect(reason)}")
        {:error, :bad_identity_info}
    end
  end

  # The first certificate of the PEM is the signer, the others its chain
  defp validate_chain(pem, trusted) do
    case for({:Certificate, der, _} <- :public_key.pem_decode(pem), do: der) do
      [leaf | chain] -> validate_chain(leaf, chain, trusted)
      [] -> {:error, :no_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  defp validate_chain(leaf, _chain, []), do: {:ok, cert_public_key(leaf)}

  defp validate_chain(leaf, chain, trusted) do
    path = Enum.reverse([leaf | chain -- trusted])

    if Enum.any?(trusted, &match?({:ok, _}, :public_key.pkix_path_validation(&1, path, []))),
      do: {:ok, cert_public_key(leaf)},
      else: {:error, :untrusted_certificate}
  end

  defp cert_public_key(der) do
    otp_cert(tbsCertificate: tbs) = :public_key.pkix_decode_cert(der, :otp)
    otp_tbs(subjectPublicKeyInfo: spki) = tbs
    otp_spki(algorithm: pk_alg(parameters: params), subjectPublicKey: point) = spki
    {point, params}
  end

  defp fetch("https://" <> _ = url) do
    opts = [timeout: 5000, ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]

    case :httpc.request(:get, {String.to_charlist(url), []}, opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, code, _}, _, _}} -> {:error, {:http_status, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(_url), do: {:error, :not_https}

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [a, b, c, 0x8000 + d, e])
    |> IO.iodata_to_binary()
  end
end
