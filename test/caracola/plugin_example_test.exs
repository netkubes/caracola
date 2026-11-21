defmodule Caracola.PluginExampleTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.Test.Client

  import Caracola.Test.Helpers

  # The plugin of guides/12-writing-plugins.md
  defmodule Blocklist do
    use Malla.Plugin, plugin_deps: [Caracola]

    @impl true
    def plugin_config(_srv_id, config) do
      ips = get_in(config, [:blocklist, :ips]) || []
      {:ok, Keyword.put(config, :blocklist, ips: ips)}
    end

    defcb caracola_callback(:sip_route, [_scheme, _user, _domain, req, call]) do
      if req.port.remote_ip in call.service.get_config()[:blocklist][:ips],
        do: {:done, {:reply, :forbidden}},
        else: :cont
    end

    defcb caracola_callback(_fun, _args), do: :cont
  end

  defmodule Blocked do
    use Malla.Service,
      plugins: [Blocklist],
      sip: [listen: "sip:127.0.0.1:0"],
      blocklist: [ips: [{127, 0, 0, 1}]]

    # The service's own sip_route/5 does not prevent the plugin from acting
    defcb sip_route(_scheme, _user, _domain, _req, _call), do: :process
  end

  test "blocklist plugin" do
    port = start_service(Blocked)
    start_service(Client)
    assert {:ok, 403, []} = Caracola.UAC.options(Client, "sip:127.0.0.1:#{port}")
  end
end
