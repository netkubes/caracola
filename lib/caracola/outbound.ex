defmodule Caracola.Outbound do
  @moduledoc """
  Client-initiated connections (RFC 5626, SIP outbound). Equivalent to
  NkSIP's `nksip_outbound`.

  ```
  defmodule MyEdgeProxy do
    use Malla.Service, plugins: [Caracola.Outbound], sip: [listen: "sip:all:5060"]
  end
  ```

  The plugin adds `outbound` to the Supported header. With it:

    * As UA, Contacts get the `+sip.instance` of the service (the
      `:instance_id` of the sip config), REGISTER requests sent with the
      `{:reg_id, n}` option a `reg-id`, and dialog-forming requests the
      `ob` parameter. See `Caracola.UACAutoOutbound` to keep the flows
      alive.
    * As registrar (with `Caracola.Registrar`), the first hop adds a Path
      with a flow token pointing to the connection the REGISTER came from,
      contacts with a `reg-id` are identified by their instance and
      `reg-id`, the response has `Require: outbound`, and a REGISTER with
      a `reg-id` through a first hop without outbound support is rejected
      with 439. Requests to the registered contacts (proxied to the
      `Caracola.Registrar.find/4` results) go through the flow.
    * As proxy, REGISTER requests proxied with `:path` (and the requests
      with a Contact with `ob`, proxied with `:record_route`) get a Path or
      Record-Route with a flow token, and requests with a route with a flow
      token are sent through that flow, or rejected with 430 (Flow Failed)
      if it is down.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  @impl true
  def plugin_config(_srv_id, config),
    do: {:ok, Caracola.Config.add_values(config, :supported, ["outbound"])}
end
