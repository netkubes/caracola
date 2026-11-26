# Getting started

## Installation

Add `caracola` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:caracola, "~> 0.1.0-rc.3"}
  ]
end
```

Caracola requires Elixir 1.18 or later. It brings
[Malla](https://hexdocs.pm/malla), whose concepts (services, plugins,
callbacks, configuration) are worth a look; this guide only covers what a
SIP application needs.

## A service

A SIP application is a Malla service using the `Caracola` plugin, or any of
the SIP plugins (they all depend on it):

```elixir
defmodule MyUA do
  use Malla.Service,
    plugins: [Caracola],
    sip: [
      listen: "sip:all:5060, <sip:all:5061;transport=tls>",
      from: "\"My UA\" <sip:my_ua@example.com>",
      tls: [certfile: "priv/cert.pem", keyfile: "priv/key.pem"]
    ]

  defcb sip_invite(_req, _call), do: {:reply, :decline}
end
```

The SIP configuration goes under the `:sip` key. The main options are:

* `:listen` - the listening addresses, as URIs. `sip:all:5060` listens on
  all the IPv4 interfaces, on port 5060, for UDP and TCP (UDP listeners
  always listen on TCP on the same port). Use `transport=tcp`, `tls`, `ws`
  or `wss` for other transports, `sips:` for TLS, port `0` for a random
  port, and `[::1]` or `all6` (any IPv6 address) for IPv6. A path is the
  HTTP path accepted by WS and WSS listeners: `<sip:all:8080/ws;transport=ws>`.
* `:from` - the default From of the requests.
* `:local_host` (and `:local_host6`) - the host in the Via, Contact and
  Record-Route headers, instead of the IP of the listener (or the main
  IP of the machine, for listeners on all interfaces).
* `:route` - routes for all the requests (an outbound proxy).
* `:tls` - `:ssl` options of the TLS and WSS listeners, and
  `:tls_client` - options of the outgoing TLS connections (the server
  certificate is verified against the system CAs by default).
* `:timer_t1`, `:timer_t2`... - SIP timers.

See `Caracola.Config` for all of them.

Configuration given when starting the service is deep-merged with the one
in the module:

```elixir
MyUA.start_link(sip: [listen: "sip:127.0.0.1:5070"])
```

Usually you will start it in your application supervisor:

```elixir
children = [
  {MyUA, sip: [listen: "sip:all:5060"]}
]
```

The SIP part of the service (its listeners and call processes) starts in
the background, after `start_link` returns. `Caracola.wait_ready/2` waits
for it, before sending the first requests:

```elixir
{:ok, _} = MyUA.start_link()
:ok = Caracola.wait_ready(MyUA)
```

`MyUA.stop()` stops it. Services can be reconfigured at runtime (see
Malla's documentation); a change in the `:sip` configuration restarts the
SIP part of the service.

## Sending requests

Requests are sent with the functions of `Caracola.UAC`, giving the service,
the destination URI and a list of options:

```elixir
iex> Caracola.UAC.options(MyUA, "sip:sip.example.com")
{:ok, 200, []}

iex> Caracola.UAC.options(MyUA, "<sip:127.0.0.1:5070;transport=tcp>",
...>   get_meta: [:reason_phrase, "server"])
{:ok, 200, [{:reason_phrase, "OK"}, {"server", ["MyServer 1.0"]}]}
```

The call waits for the final response, and returns its code and the values
asked for with `:get_meta`. See [Sending requests](04-sending-requests.md).

## Receiving requests

Incoming requests go through the `sip_*` callbacks of the service.
`sip_route/5` decides what to do with each request (process it, proxy it
or reply at once) and, for the requests to process, the callback of its
method (`sip_invite/2`, `sip_options/2`, `sip_register/2`...) replies to it:

```elixir
defcb sip_options(_req, _call), do: {:reply, {:ok, [:allow, :supported]}}
```

Any callback you do not implement has a default (OPTIONS are answered,
INVITEs declined, REGISTERs rejected unless you use the registrar plugin...).
See [Receiving requests](05-receiving-requests.md).

## Plugins

SIP extensions are plugins, listed in `:plugins` instead of (or with)
`Caracola`:

```elixir
use Malla.Service,
  plugins: [Caracola.Registrar, Caracola.Rel100],
  sip: [listen: "sip:all:5060"],
  registrar: [min_time: 60]
```

See [Plugins](10-plugins.md).

## Tracing messages

To see the SIP messages sent and received, while developing:

```elixir
Caracola.Telemetry.trace(true)
```

They are logged at the `:info` level. See [Observability](11-observability.md).
