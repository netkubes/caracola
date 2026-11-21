# Introduction

Caracola is a SIP stack for Elixir. It lets you build any kind of SIP
application: endpoints (user agents), registrars, proxies (stateless or
stateful, with forking), redirect servers, B2BUAs, presence servers or load
generators.

It is a rewrite of [NkSIP](https://github.com/NetComposer/nksip), keeping
its proven design and most of its behaviour, built on the
[Malla](https://github.com/netkubes/malla) service framework instead of
NkSERVICE and NkPACKET.

## Features

**Core**

* Full SIP core (RFC 3261): transactions (INVITE and non-INVITE, client
  and server), dialogs, CANCEL, the ACK of 2xx responses, retransmissions
  and timers.
* Transports: UDP, TCP, TLS, WS and WSS (RFC 7118), over IPv4 and IPv6. UDP
  listeners also listen on TCP on the same port. Connections are reused,
  and closed when idle. Large UDP messages switch to TCP.
* DNS resolution following RFC 3263 (NAPTR, SRV, A and AAAA), with a cache.
* Digest authentication (RFC 8760: MD5, SHA-256 and SHA-512-256), as
  server and as client.
* Offer/answer of SDP sessions (RFC 3264), with a SDP parser and generator,
  and WebRTC utilities.
* Event subscriptions: SUBSCRIBE and NOTIFY (RFC 6665), and REFER (RFC 3515).

**Proxies and routing**

* Stateless and stateful proxies, parallel and serial forking, redirects,
  Record-Route and Path (RFC 3327).
* Destination groups with load balancing, health checks and failover
  (`Caracola.Dispatcher`), and History-Info and Diversion
  (`Caracola.History`).

**Plugins**, described in the [plugins guide](10-plugins.md):

* *Registration and NAT*: registrar (also shared by a cluster), SIP
  outbound (RFC 5626) with keepalives, GRUU (RFC 5627), automatic
  registrations, push notifications (RFC 8599).
* *Call control*: 100rel (RFC 3262), session timers (RFC 4028), REFER,
  Replaces (RFC 3891), Join (RFC 3911), INFO packages (RFC 6086), SIPREC
  (RFC 7866) and a B2BUA.
* *Events and presence*: PUBLISH (RFC 3903), presence (RFC 3856), dialog
  state (RFC 4235), message waiting (RFC 3842), conference state
  (RFC 4575) and watcher information (RFC 3857).
* *Security and load*: asserted identity (RFC 3325), STIR/SHAKEN
  (RFC 8224), rate limiting and overload control (RFC 7339).

**Operation**

* `:telemetry` events for messages, calls, transactions and dialogs, and
  HEP capture to Homer.
* Hot reconfiguration and runtime plugins, from Malla.

## How it works

A SIP application is a **service**: a module using `Malla.Service` with
the `Caracola` plugin (or another SIP plugin, which depends on it). The
service listens on one or more addresses, sends requests with
`Caracola.UAC` and receives them in **callbacks** (`sip_invite/2`,
`sip_options/2`...), which you implement with `defcb`.

```elixir
defmodule MyUA do
  use Malla.Service,
    plugins: [Caracola],
    sip: [listen: "sip:all:5060"]

  defcb sip_invite(_req, _call), do: {:reply, :busy}
end
```

Some concepts you will find through the documentation:

* **Call**: all the requests, responses, transactions and dialogs sharing a
  Call-ID are handled by a single Erlang process, the call process (see
  `Caracola.Call`). It is started when the first message arrives (or is
  sent) and stops when nothing is left. Your callbacks run in the call
  process, so they must return quickly; slow work goes to other processes,
  which reply later with `Caracola.reply/2`.
* **Transactions**: each request and its responses. Caracola handles them
  (retransmissions, timers, matching of responses and CANCELs) for you.
* **Dialogs**: created by INVITE (and SUBSCRIBE, REFER...) and identified by
  a handle, `{:dialog, service, call_id, id}`, that you use to send
  in-dialog requests, as `Caracola.UAC.bye/3`. See `Caracola.Dialog`.
* **Subscriptions**: event subscriptions inside a dialog, identified by a
  handle too. See `Caracola.Subscription`.
* **Messages**: requests and responses are `Caracola.Message` structs, with
  the main headers parsed (From, To, Via, Contact, Route...).
* **Replies**: callbacks answer with a code or a shortcut (`:ok`,
  `:busy`, `{:redirect, contacts}`...), see `Caracola.Reply`.

## What next

* [Getting started](02-getting-started.md) shows how to add Caracola to a
  project, configure a service and send the first requests.
* The [tutorial](03-tutorial.md) builds a small proxy with authentication
  and a registrar, and two clients calling each other through it.
* [A small PBX](15-small-pbx.md) uses the registrar, B2BUA, dialog state and
  call history plugins.
* If you know NkSIP, see [Migrating from NkSIP](13-migrating-from-nksip.md).
