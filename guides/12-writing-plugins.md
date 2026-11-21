# Writing plugins

SIP extensions are [Malla plugins](https://hexdocs.pm/malla/04-plugins.html).
A plugin depends on `Caracola` (or on other SIP plugins), can change the
configuration of the service, start processes, and implement callbacks.

```elixir
defmodule MyApp.Blocklist do
  @moduledoc "Rejects the requests coming from some addresses."

  use Malla.Plugin, plugin_deps: [Caracola]

  @impl true
  def plugin_config(_srv_id, config) do
    ips = get_in(config, [:blocklist, :ips]) || []
    {:ok, Keyword.put(config, :blocklist, ips: ips)}
  end

  # Before the sip_route/5 of the service (see "Callback chain" below)
  defcb caracola_callback(:sip_route, [_scheme, _user, _domain, req, call]) do
    if req.port.remote_ip in call.service.get_config()[:blocklist][:ips],
      do: {:done, {:reply, :forbidden}},
      else: :cont
  end

  defcb caracola_callback(_fun, _args), do: :cont
end
```

```elixir
defmodule MyServer do
  use Malla.Service,
    plugins: [MyApp.Blocklist, Caracola.Registrar],
    sip: [listen: "sip:all:5060"],
    blocklist: [ips: [{10, 0, 0, 66}]]
end
```

## Callback chain

Callbacks are chained at compile time: the service itself first, then its
plugins (each one before its dependencies), and `Caracola` last, with the
defaults. A callback returning `:cont` passes to the next one (or
`{:cont, new_args}`, with other arguments); anything else is the result.

So a plugin can implement any `sip_*` callback, as the defaults of
`Caracola.Registrar` (`sip_register/2`) or `Caracola.Refer` (`sip_refer/2`),
and the service can still override it.

Some callbacks exist to be extended by plugins:

* `sip_authorize_data(list, req, call)` builds the authorization list of
  `sip_authorize/3`: a plugin can add values with
  `{:cont, [[value | list], req, call]}` (the registrar adds `:register`).
* `caracola_callback(fun, args)` is called before the callbacks that the
  call process makes to the service: the request methods, `sip_route/5`,
  `sip_authorize/3`, `sip_dialog_update/3`... but not the callbacks of
  plugins (`fun` is its name, as `:sip_notify`, and `args` its arguments).
  Returning `:cont` calls the callback; `{:done, result}` uses `result`
  instead. Plugins use it to see or handle callbacks before the service,
  which comes first in the chain: `Caracola.Refer` handles the NOTIFYs of
  REFER subscriptions this way, whatever `sip_notify/2` the service has.

Plugins can also define new callbacks, with a default implementation, for
the services to implement (as `sip_refer_update/3` in `Caracola.Refer`).

## Configuration

`c:Malla.Plugin.plugin_config/2` gets the configuration of the service and
returns it, changed. Plugins usually validate their own key (with
`NimbleOptions`), and add their methods and option tags with
`Caracola.Config.add_values/3`:

```elixir
@impl true
def plugin_config(_srv_id, config) do
  config = Caracola.Config.add_values(config, :allow, ["PUBLISH"])
  {:ok, config}
end
```

Plugins listed first are configured first, so a plugin sees the
configuration before `Caracola` validates the `:sip` key.

## Processes

`c:Malla.Plugin.plugin_start/2` returns the children to start with the
service, under a supervisor of the plugin:

```elixir
@impl true
def plugin_start(srv_id, _config),
  do: {:ok, children: [{MyApp.Blocklist.Store, srv_id}]}
```

They are stopped with the service, before the SIP listeners.

## In the call process

Callbacks run in the process of the call (a `Caracola.Call`): they get its
state, but can not change it, and must not block. Use other processes for
slow work, and `Caracola.reply/2` or `Caracola.UAC` from them.

## Testing

Start the services with `start_supervised!/1` in your tests, on random
ports (`listen: "sip:127.0.0.1:0"`), and get them with
`Caracola.listeners/1`. The tests of Caracola are a good source of
examples.
