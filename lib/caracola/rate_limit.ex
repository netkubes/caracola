defmodule Caracola.RateLimit do
  @moduledoc """
  Rate limiting and banning of abusive clients: request rate limits per
  address and per user, and bans of SIP scanners and of addresses with too
  many failed authentications (brute-force attacks).

  ```
  defmodule MyProxy do
    use Malla.Service,
      plugins: [Caracola.RateLimit, Caracola.Registrar],
      sip: [listen: "sip:all:5060"],
      rate_limit: [per_ip: {50, 1000}, per_user: {10, 1000}, exempt: ["10.0.0.0/8"]]
  end
  ```

  Requests are checked in the transport process, as soon as they are
  received and before a call process is started for them, so rejecting
  them is cheap. For each request:

    1. Requests from `:exempt` addresses are accepted.
    2. Requests from banned addresses are dropped silently.
    3. Requests with the `User-Agent` of a known scanner (`:scanners`) are
       dropped, and their address is banned.
    4. If the address (`:per_ip`) or the user of the From header
       (`:per_user`) sent too many requests, the request is rejected with
       the `:reply` (a 503 with `Retry-After` by default, or `:drop`).

  ACKs are never rejected (only dropped if banned) and are not counted.
  Limits are given as `{requests, milliseconds}`, and counted in fixed
  windows of that time.

  Requests whose digest credentials are wrong (`{{:digest, realm}, false}`
  in `sip_authorize/3`) count as authentication failures of their
  address, which is banned when there are too many of them
  (`:auth_failures`). Bans last `:ban_time` milliseconds, see also
  `ban/3` and `unban/2`.

  Rejections and bans emit the `[:caracola, :rate_limit, :reject]` and
  `[:caracola, :rate_limit, :ban]` telemetry events, with a `:count` (or
  `:time`) measurement and the `:service`, `:ip` and `:reason` (`:per_ip`,
  `:per_user`, `:banned`, `:scanner` or `:auth_failures`) as metadata.

  The plugin should be the first one of the service, so that its
  `sip_authorize/3` hook sees the result of the authentication before
  other plugins.

  ## Configuration

  Under the `:rate_limit` key:

    * `:per_ip` - requests per address, as `{requests, ms}` (default
      `{100, 1000}`), `nil` for no limit.
    * `:per_user` - requests per user of the From header (default `nil`).
    * `:auth_failures` - authentication failures per address before it is
      banned (default `{10, 60_000}`), `nil` for no bans.
    * `:scanners` - fragments of the `User-Agent` of scanners
      (case-insensitive), banned at once. The default list has
      `friendly-scanner`, `sipvicious`, `sipcli` and other common ones;
      `[]` disables it.
    * `:ban_time` - duration of bans, in milliseconds (default 600000).
    * `:exempt` - addresses with no limits nor bans, as `10.0.0.0/8` or
      `192.0.2.1` (default `[]`).
    * `:reply` - reply to the requests over a limit (default a 503 with
      `Retry-After: 5`), or `:drop` to discard them.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  require Logger

  alias Caracola.{Message, Util}
  alias Caracola.RateLimit.Store

  @scanners [
    "friendly-scanner",
    "sipvicious",
    "sipcli",
    "sip-scan",
    "sipscan",
    "iwar",
    "sundayddr",
    "vaxsipuseragent",
    "pplsip",
    "sipbomber"
  ]

  @limit {:or, [{:tuple, [:pos_integer, :pos_integer]}, {:in, [nil]}]}

  @schema NimbleOptions.new!(
            per_ip: [
              type: @limit,
              default: {100, 1000},
              doc: "Requests per address, as `{requests, ms}`, `nil` for no limit."
            ],
            per_user: [
              type: @limit,
              default: nil,
              doc: "Requests per user (of the From header), `nil` for no limit."
            ],
            auth_failures: [
              type: @limit,
              default: {10, 60_000},
              doc: "Authentication failures per address before it is banned."
            ],
            scanners: [
              type: {:list, :string},
              default: @scanners,
              doc: "User-Agent fragments (case-insensitive) of the scanners to ban."
            ],
            ban_time: [
              type: :pos_integer,
              default: 600_000,
              doc: "Duration of bans, in milliseconds."
            ],
            exempt: [
              type: {:list, :string},
              default: [],
              doc: "Addresses with no limits, as `10.0.0.0/8` or `192.0.2.1`."
            ],
            reply: [
              type: :any,
              default: {503, [{:add, "retry-after", "5"}]},
              doc: "Reply to requests over a limit (see `Caracola.Reply`), or `:drop`."
            ]
          )

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc "Bans an address for `time` milliseconds (the `:ban_time` by default)."
  @spec ban(module(), :inet.ip_address(), pos_integer() | nil) :: :ok
  def ban(service, ip, time \\ nil) do
    time = time || config(service)[:ban_time]
    Logger.notice("SIP address #{:inet.ntoa(ip)} banned for #{time} ms", service: service)

    :telemetry.execute([:caracola, :rate_limit, :ban], %{time: time}, %{
      service: service,
      ip: ip,
      reason: :manual
    })

    Store.ban(service, ip, time)
  end

  @doc "Removes the ban of an address."
  @spec unban(module(), :inet.ip_address()) :: :ok
  def unban(service, ip), do: Store.unban(service, ip)

  @doc "Returns `true` if an address is banned."
  @spec banned?(module(), :inet.ip_address()) :: boolean()
  def banned?(service, ip), do: Store.banned?(service, ip)

  @doc "The banned addresses, with the milliseconds left."
  @spec bans(module()) :: [{:inet.ip_address(), non_neg_integer()}]
  def bans(service), do: Store.bans(service)

  @doc "Removes all the counters and bans of a service."
  @spec clear(module()) :: :ok
  def clear(service), do: Store.clear(service)

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <- NimbleOptions.validate(Keyword.get(config, :rate_limit, []), @schema),
         {:ok, exempt} <- Util.parse_networks(opts[:exempt]) do
      opts =
        opts
        |> Keyword.put(:exempt, exempt)
        |> Keyword.update!(:scanners, fn list -> Enum.map(list, &String.downcase/1) end)

      {:ok, Keyword.put(config, :rate_limit, opts)}
    end
  end

  defcb caracola_received_message(
          %Message{class: {:req, method}, service: service, port: %{remote_ip: ip}} = req
        ) do
    config = config(service)

    cond do
      Util.in_networks?(ip, config[:exempt]) ->
        :cont

      Store.banned?(service, ip) ->
        reject(service, ip, :banned, :drop)

      scanner?(req, config[:scanners]) ->
        auto_ban(service, ip, config[:ban_time], :scanner)

      method == :ack ->
        :cont

      over?(service, :ip, ip, config[:per_ip]) ->
        reject(service, ip, :per_ip, config[:reply])

      over?(service, :user, user(req), config[:per_user]) ->
        reject(service, ip, :per_user, config[:reply])

      true ->
        :cont
    end
  end

  def caracola_received_message(_msg), do: :cont

  defcb caracola_callback(:sip_authorize, [auth_list, %Message{port: %{remote_ip: ip}}, call]) do
    service = call.service

    if Enum.any?(auth_list, &match?({{:digest, _}, false}, &1)) do
      config = config(service)

      if not Util.in_networks?(ip, config[:exempt]) and
           over?(service, :auth, ip, config[:auth_failures]),
         do: auto_ban(service, ip, config[:ban_time], :auth_failures)
    end

    :cont
  end

  def caracola_callback(_fun, _args), do: :cont

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp config(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> Keyword.get(config, :rate_limit, [])
      _ -> []
    end
  end

  defp over?(_service, _class, _id, nil), do: false
  defp over?(_service, _class, nil, _limit), do: false

  defp over?(service, class, id, {limit, interval}),
    do: Store.hit(service, class, id, interval) > limit

  defp user(%Message{from: %{user: user, domain: domain}}) when is_binary(user),
    do: {user, Util.ascii_downcase(domain)}

  defp user(_req), do: nil

  defp scanner?(_req, []), do: false

  defp scanner?(req, scanners) do
    case Message.header(req, "user-agent") do
      [ua | _] -> String.contains?(String.downcase(ua), scanners)
      [] -> false
    end
  end

  defp auto_ban(service, ip, time, reason) do
    if not Store.banned?(service, ip) do
      Logger.notice("SIP address #{:inet.ntoa(ip)} banned (#{reason})", service: service)

      :telemetry.execute([:caracola, :rate_limit, :ban], %{time: time}, %{
        service: service,
        ip: ip,
        reason: reason
      })

      Store.ban(service, ip, time)
    end

    :drop
  end

  defp reject(service, ip, reason, reply) do
    :telemetry.execute([:caracola, :rate_limit, :reject], %{count: 1}, %{
      service: service,
      ip: ip,
      reason: reason
    })

    if reply == :drop, do: :drop, else: {:reply, reply}
  end
end
