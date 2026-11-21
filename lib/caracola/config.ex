defmodule Caracola.Config do
  @default_allow ~w(INVITE ACK CANCEL BYE OPTIONS INFO UPDATE SUBSCRIBE NOTIFY REFER MESSAGE)
  @default_supported ~w(path)

  @schema [
    listen: [
      type: :string,
      doc:
        "Listening URIs, for example `\"sip:all:5060, <sip:all:5061;transport=tls>\"`. " <>
          "For WS and WSS, a path accepts only that HTTP path " <>
          "(`\"<sip:all:8080/ws;transport=ws>\"`)."
    ],
    allow: [
      type: {:custom, __MODULE__, :validate_words, []},
      default: @default_allow,
      doc: "Methods sent in the Allow header."
    ],
    supported: [
      type: {:custom, __MODULE__, :validate_words, []},
      default: @default_supported,
      doc: "Option tags sent in the Supported header."
    ],
    timer_t1: [type: {:in, 10..2500}, default: 500, doc: "Timer T1 (msecs)."],
    timer_t2: [type: {:in, 100..16_000}, default: 4000, doc: "Timer T2 (msecs)."],
    timer_t4: [type: {:in, 100..25_000}, default: 5000, doc: "Timer T4 (msecs)."],
    timer_c: [type: :pos_integer, default: 180, doc: "Timer C (secs)."],
    trans_timeout: [
      type: {:custom, __MODULE__, :validate_min, [5]},
      default: 900,
      doc:
        "Transaction timeout (secs): every `2 * trans_timeout` seconds, calls remove the " <>
          "transactions older than that, replying `{:error, :timeout}` to their callers."
    ],
    dialog_timeout: [
      type: {:custom, __MODULE__, :validate_min, [5]},
      default: 1800,
      doc:
        "Dialog timeout (secs): dialogs without activity are ended with a BYE " <>
          "(and removed after twice this time)."
    ],
    event_expires: [
      type: :pos_integer,
      default: 60,
      doc: "Default subscription expiration (secs)."
    ],
    event_expires_offset: [
      type: :non_neg_integer,
      default: 5,
      doc: "Extra time before a subscription is removed (secs)."
    ],
    session_expires: [
      type: {:custom, __MODULE__, :validate_min, [5]},
      default: 1800,
      doc: "Session interval for session timers (secs, see `Caracola.SessionTimers`)."
    ],
    min_se: [
      type: :pos_integer,
      default: 90,
      doc: "Minimum session interval accepted for session timers (secs)."
    ],
    digest_algorithms: [
      type: {:list, {:in, [:md5, :sha256, :sha512_256]}},
      default: [:md5],
      doc:
        "Digest algorithms accepted from clients (RFC 8760): `:md5`, `:sha256` and " <>
          "`:sha512_256`. Challenges offer them, the strongest first."
    ],
    nonce_timeout: [
      type: {:custom, __MODULE__, :validate_min, [5]},
      default: 30,
      doc: "Validity of digest auth nonces (secs)."
    ],
    from: [type: :string, doc: "Default From URI."],
    accept: [type: {:custom, __MODULE__, :validate_words, []}, doc: "Default Accept values."],
    events: [
      type: {:custom, __MODULE__, :validate_words, []},
      default: [],
      doc: "Supported event packages."
    ],
    info_packages: [
      type: {:custom, __MODULE__, :validate_words, []},
      doc:
        "INFO packages received (RFC 6086), sent in the Recv-Info header of INVITEs " <>
          "and their responses. Without it, no Recv-Info is sent (see `Caracola.InfoPackages`)."
    ],
    route: [type: {:list, :string}, default: [], doc: "Default Route URIs."],
    no_100: [type: :boolean, default: false, doc: "Do not send automatic 100 Trying."],
    max_calls: [type: {:in, 1..1_000_000}, default: 100_000, doc: "Maximum concurrent calls."],
    local_host: [
      type: {:or, [{:in, [:auto]}, :string]},
      default: :auto,
      doc: "Host used in Via and Contact (IPv4)."
    ],
    local_host6: [
      type: {:or, [{:in, [:auto]}, :string]},
      default: :auto,
      doc: "Host used in Via and Contact (IPv6)."
    ],
    tls: [
      type: :keyword_list,
      default: [],
      doc: "`:ssl` options for TLS and WSS listeners (`certfile`, `keyfile`...)."
    ],
    tls_client: [
      type: :keyword_list,
      doc: "`:ssl` options for outgoing TLS connections, merged with the defaults."
    ],
    password: [
      type: :any,
      doc:
        "Passwords to answer digest challenges: a password, an HA1 (`{:ha1, hex}` for MD5 " <>
          "or `{:ha1, algorithm, hex}`, see `Caracola.Digest.ha1/4`), `{realm, password}` " <>
          "or a list of them. Used after the ones in the request options."
    ],
    auto_auth_max_tries: [
      type: :non_neg_integer,
      default: 5,
      doc: "Maximum number of times a challenged request is sent again with credentials."
    ],
    udp_max_size: [
      type: :non_neg_integer,
      default: 1300,
      doc: "Requests larger than this are sent over TCP."
    ],
    via_params: [
      type: {:list, {:tuple, [:string, {:or, [:string, {:in, [nil]}]}]}},
      default: [],
      doc: "Parameters added to the Via of the requests sent, as `{name, value}` (for plugins)."
    ],
    instance_id: [
      type: :string,
      doc:
        "Instance id (RFC 5626 `+sip.instance`, used by outbound and GRUU), " <>
          "like `\"<urn:uuid:...>\"`. By default, one derived from the service and node names."
    ]
  ]

  @schema NimbleOptions.new!(@schema)

  @moduledoc """
  Configuration schema for SIP services, placed under the `:sip` key.

  Equivalent to NkSIP's `nksip_syntax:app_syntax/0` (without the `sip_` prefix).
  Defaults match NkSIP's `nksip_syntax:make_config/1`.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @typedoc "The validated sip configuration of a service, as a keyword list."
  @type t :: keyword()

  @doc """
  Validates SIP options and fills in defaults.
  """
  @spec validate(keyword()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def validate(opts), do: NimbleOptions.validate(opts, @schema)

  @doc false
  def default_allow, do: @default_allow

  @doc false
  def default_supported, do: @default_supported

  @doc """
  Adds values to the `:allow`, `:supported`, `:events` or `:info_packages` list of the sip configuration
  of a service, for plugins (in their `c:Malla.Plugin.plugin_config/2`):

      def plugin_config(_srv_id, config),
        do: {:ok, Caracola.Config.add_values(config, :supported, ["myext"])}
  """
  @spec add_values(keyword(), :allow | :supported | :events | :info_packages, [String.t()]) ::
          keyword()
  def add_values(config, key, values) when key in [:allow, :supported, :events, :info_packages] do
    sip = Keyword.get(config, :sip, [])

    default =
      case key do
        :allow -> @default_allow
        :supported -> @default_supported
        :events -> []
        :info_packages -> []
      end

    current =
      case Keyword.get(sip, key, default) do
        words when is_binary(words) -> String.split(words, [",", " "], trim: true)
        words -> words
      end

    Keyword.put(config, :sip, Keyword.put(sip, key, Enum.uniq(current ++ values)))
  end

  @doc false
  # Accepts a list of strings or a comma or space separated string
  def validate_words(words) when is_binary(words),
    do: {:ok, String.split(words, [",", " "], trim: true)}

  def validate_words(words) when is_list(words) do
    if Enum.all?(words, &is_binary/1),
      do: {:ok, words},
      else: {:error, "expected a list of strings, got: #{inspect(words)}"}
  end

  def validate_words(other),
    do: {:error, "expected a string or a list of strings, got: #{inspect(other)}"}

  @doc false
  def validate_min(value, min) when is_integer(value) and value >= min, do: {:ok, value}

  def validate_min(value, min),
    do: {:error, "expected an integer >= #{min}, got: #{inspect(value)}"}
end
