defmodule Caracola.UACAutoRegister do
  @moduledoc """
  Automatic registrations and pings. Equivalent to NkSIP's
  `nksip_uac_auto_register`.

  ```
  defmodule MyUA do
    use Malla.Service,
      plugins: [Caracola.UACAutoRegister],
      sip: [listen: "sip:all:5060"],
      uac_auto_register: [timer: 5]
  end

  {:ok, true} = Caracola.UACAutoRegister.start_register(MyUA, :reg1, "sip:registrar.com", [])
  ```

  `start_register/4` sends a REGISTER (with a Contact and the
  options given, see `Caracola.UAC`) and keeps refreshing it before it
  expires (`expires: 300` by default). `start_ping/4` sends an OPTIONS
  every `expires` seconds (300 by default). Both return when the first
  response arrives, with `{:ok, true}` for a 2xx and `{:ok, false}`
  otherwise. Failed registrations and pings are retried after the same
  time (or the Retry-After of a 503).

  Changes in their state are notified with the callbacks
  `sip_uac_auto_register_updated_reg(id, ok, service)` and
  `sip_uac_auto_register_updated_ping(id, ok, service)`.

  Registrations are removed (sending a REGISTER with `expires: 0`) with
  `stop_register/2`, and when the service stops.

  ## Configuration

  Under the `:uac_auto_register` key:

    * `:timer` - interval (secs) to check if registrations and pings must
      be sent (5 by default).
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.UACAutoRegister.Server

  @schema NimbleOptions.new!(
            timer: [type: :pos_integer, default: 5, doc: "Check interval (secs)."]
          )

  @typedoc "Identifies a registration."
  @type id :: term()

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Starts an automatic registration, replacing any other with the same `id`.
  `uri` is the registrar.
  """
  @spec start_register(module(), id(), String.t() | Caracola.URI.t(), list()) ::
          {:ok, boolean()} | {:error, term()}
  def start_register(service, id, uri, opts \\ []), do: start(service, :reg, id, uri, opts)

  @doc "Stops an automatic registration, unregistering it."
  @spec stop_register(module(), id()) :: :ok | :not_found
  def stop_register(service, id), do: Server.call(service, {:stop, :reg, id})

  @doc """
  Returns the automatic registrations: their id, if the last one was
  successful, and the seconds to the next one.
  """
  @spec get_registers(module()) :: [{id(), boolean() | nil, integer()}]
  def get_registers(service), do: Server.call(service, {:get, :reg})

  @doc """
  Returns the Service-Route (RFC 3608) of the last successful response to
  a registration: the routes to use as the `:route` of the requests sent
  through that registrar (`[]` if it returned none, or the registration
  is not found).

      routes = Caracola.UACAutoRegister.service_route(MyUA, :reg1)
      Caracola.UAC.invite(MyUA, "sip:bob@example.com", route: routes)
  """
  @spec service_route(module(), id()) :: [String.t()]
  def service_route(service, id), do: Server.call(service, {:service_route, id})

  @doc "Starts sending OPTIONS to `uri` periodically."
  @spec start_ping(module(), id(), String.t() | Caracola.URI.t(), list()) ::
          {:ok, boolean()} | {:error, term()}
  def start_ping(service, id, uri, opts \\ []), do: start(service, :ping, id, uri, opts)

  @doc "Stops a ping."
  @spec stop_ping(module(), id()) :: :ok | :not_found
  def stop_ping(service, id), do: Server.call(service, {:stop, :ping, id})

  @doc "Returns the pings, as `get_registers/1`."
  @spec get_pings(module()) :: [{id(), boolean() | nil, integer()}]
  def get_pings(service), do: Server.call(service, {:get, :ping})

  defp start(service, class, id, uri, opts) do
    cond do
      Caracola.Util.opt?(opts, :get_meta) -> {:error, :meta_not_allowed}
      not valid_uri?(uri) -> {:error, :invalid_uri}
      true -> Server.call(service, {:start, class, id, uri, opts}, :infinity)
    end
  end

  defp valid_uri?(%Caracola.URI{}), do: true
  defp valid_uri?(uri) when is_binary(uri), do: match?({:ok, _}, Caracola.URI.parse_one(uri))
  defp valid_uri?(_uri), do: false

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <-
           NimbleOptions.validate(Keyword.get(config, :uac_auto_register, []), @schema),
         do: {:ok, Keyword.put(config, :uac_auto_register, opts)}
  end

  @impl true
  def plugin_start(srv_id, config) do
    timer = get_in(config, [:uac_auto_register, :timer]) || 5
    # With Caracola.UACAutoOutbound
    ob_config = config[:uac_auto_outbound]
    {:ok, children: [{Server, {srv_id, timer, ob_config}}]}
  end

  defcb sip_uac_auto_register_updated_reg(_id, _ok, _service), do: :ok

  defcb sip_uac_auto_register_updated_ping(_id, _ok, _service), do: :ok
end
