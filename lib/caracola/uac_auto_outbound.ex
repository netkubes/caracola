defmodule Caracola.UACAutoOutbound do
  @moduledoc """
  Automatic registrations with outbound (RFC 5626). Equivalent to NkSIP's
  `nksip_uac_auto_outbound`.

  ```
  defmodule MyUA do
    use Malla.Service,
      plugins: [Caracola.UACAutoOutbound],
      sip: [listen: "sip:all:5060"]
  end

  {:ok, true} = Caracola.UACAutoOutbound.start_register(MyUA, :reg1, "<sip:registrar.com;transport=tcp>")
  ```

  It uses `Caracola.UACAutoRegister` and `Caracola.Outbound`. Registrations
  started with `start_register/4` get a `reg-id` (the `:reg_id` option, or
  the next free one) and, if the registrar supports outbound, their flow is
  kept alive with CRLF pings (TCP and TLS) or STUN requests (UDP), every
  Flow-Timer seconds of the registrar or the defaults below (minus up to
  20%). When the flow fails, or a registration fails, it is sent again
  after a random time between 50% and 100% of
  `min(max_time, base * 2^failures)`, where `base` is `all_fail` if all the
  outbound registrations are failing and `any_ok` otherwise (RFC 5626
  §4.5).

  ## Configuration

  Under the `:uac_auto_outbound` key (seconds):

    * `:all_fail` - base time when all the registrations fail (30).
    * `:any_ok` - base time when some registration works (90).
    * `:max_time` - maximum time between retries (1800).
    * `:udp_ttl` - keepalive interval for UDP (25).
    * `:tcp_ttl` - keepalive interval for TCP and TLS (120).
  """

  use Malla.Plugin, plugin_deps: [Caracola.UACAutoRegister, Caracola.Outbound]

  alias Caracola.UACAutoRegister
  alias Caracola.UACAutoRegister.Server

  @schema NimbleOptions.new!(
            all_fail: [type: :pos_integer, default: 30, doc: "Base time when all fail."],
            any_ok: [type: :pos_integer, default: 90, doc: "Base time when some works."],
            max_time: [type: :pos_integer, default: 1800, doc: "Maximum retry time."],
            udp_ttl: [type: :pos_integer, default: 25, doc: "UDP keepalive interval."],
            tcp_ttl: [type: :pos_integer, default: 120, doc: "TCP keepalive interval."]
          )

  @doc """
  Starts an automatic registration with outbound. See
  `Caracola.UACAutoRegister.start_register/4`.
  """
  @spec start_register(module(), term(), String.t() | Caracola.URI.t(), list()) ::
          {:ok, boolean()} | {:error, term()}
  def start_register(service, id, uri, opts \\ []),
    do: UACAutoRegister.start_register(service, id, uri, [:auto_outbound | opts])

  @doc "Stops an automatic registration. See `Caracola.UACAutoRegister.stop_register/2`."
  @spec stop_register(module(), term()) :: :ok | :not_found
  def stop_register(service, id), do: UACAutoRegister.stop_register(service, id)

  @doc """
  Returns the outbound registrations: their id, if the last one was
  successful, the seconds to the next one and the number of consecutive
  failures.
  """
  @spec get_registers(module()) :: [{term(), boolean() | nil, integer(), non_neg_integer()}]
  def get_registers(service), do: Server.call(service, :get_outbound)

  @doc false
  # The keepalive processes of the registrations, for tests
  def get_keepalives(service), do: Server.call(service, :get_keepalives)

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <-
           NimbleOptions.validate(Keyword.get(config, :uac_auto_outbound, []), @schema),
         do: {:ok, Keyword.put(config, :uac_auto_outbound, opts)}
  end
end
