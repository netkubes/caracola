# Caracola

A SIP stack for Elixir, to build user agents, registrars, proxies,
redirect servers, B2BUAs and any other SIP application.

Caracola is a rewrite of [NkSIP](https://github.com/NetComposer/nksip)
built on the [Malla](https://github.com/netkubes/malla) service framework.
Its name is Spanish for the conch shell that sailors and fishermen blew to
call each other across the sea.

```elixir
defmodule MyUA do
  use Malla.Service,
    plugins: [Caracola],
    sip: [listen: "sip:all:5060"]

  defcb sip_invite(req, _call) do
    spawn(fn ->
      :ok = Caracola.reply(req, :ringing)
      Caracola.reply(req, {:answer, Caracola.SDP.from_message(req)})
    end)

    :noreply
  end
end

{:ok, _} = MyUA.start_link()
:ok = Caracola.wait_ready(MyUA)
{:ok, 200, []} = Caracola.UAC.options(MyUA, "sip:sip.example.com")
```

## Features

* **Core**: SIP (RFC 3261) with transactions, dialogs, CANCEL and timers;
  UDP, TCP, TLS, WS and WSS (RFC 7118) over IPv4 and IPv6; RFC 3263 DNS.
* **Proxies**: stateless and stateful, with forking, redirects,
  Record-Route and Path; destination groups with load balancing and
  failover (`Caracola.Dispatcher`).
* **Authentication**: digest with MD5, SHA-256 and SHA-512-256, as server
  and as client.
* **Media signalling**: SDP offer/answer, WebRTC utilities (ICE and
  trickle ICE, DTLS-SRTP, BUNDLE), SIPREC session recording.
* **Registration and NAT**: registrar (also shared in a cluster), SIP
  outbound with keepalives, GRUU, automatic registrations, push
  notifications for mobile devices.
* **Call control**: 100rel, session timers, REFER, Replaces, Join,
  INFO packages, History-Info and a B2BUA.
* **Events and presence**: SUBSCRIBE/NOTIFY, PUBLISH, presence, dialog
  state for busy lamps, message waiting, conference state and watcher
  information.
* **Security and load**: asserted identity and privacy, STIR/SHAKEN, rate
  limiting and overload control.
* **Observability**: `:telemetry` events, message tracing and HEP capture
  for Homer.

See the [plugins guide](guides/10-plugins.md) for the complete list.

## Installation

```elixir
def deps do
  [
    {:caracola, "~> 0.1.0-rc.2"}
  ]
end
```

## Documentation

The guides start with the [introduction](guides/01-introduction.md) and
[getting started](guides/02-getting-started.md), and the
[tutorial](guides/03-tutorial.md) builds a proxy with authentication and
two clients, and [a small PBX](guides/15-small-pbx.md) uses the registrar,
B2BUA and dialog state plugins. NkSIP users can read
[Migrating from NkSIP](guides/13-migrating-from-nksip.md). SIPp, FreeSWITCH,
baresip and Asterisk interoperability, and load results, are in
[Interoperability and performance](guides/14-interoperability-and-performance.md),
and planned work in the [roadmap](ROADMAP.md).

Generate the documentation with:

```bash
mix docs
```

## Development

```bash
mix deps.get
mix ci        # format check, compile with warnings as errors, credo, dialyzer, tests
```

The tutorial services are in `examples/tutorial`, compiled in the `dev`
and `test` environments.

## License

Copyright 2026 Erlnets Technologies. Licensed under the
[Apache License, Version 2.0](LICENSE.md).
