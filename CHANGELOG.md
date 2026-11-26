# Changelog

## 0.1.0-rc.3 (2026-11-26)

* `LICENSE` is now the verbatim text of the Apache License 2.0 (the
  previous `LICENSE.md` was not), and the copyright notice is in `NOTICE`.
* README: links to the documentation on HexDocs and to the Hex package.

## 0.1.0-rc.2 (2026-11-22)

* `Caracola.ready?/1` and `Caracola.wait_ready/2`: the SIP part of a
  service starts in the background, after `start_link` returns, so
  requests sent at once failed with `{:error, :service_not_started}`.
* Requests sent while a service is starting or stopping return
  `{:error, :service_not_started}` instead of raising an `ArgumentError`.
* Guides: fixes in the examples of the small PBX tutorial, getting
  started, sending and receiving requests, proxies, authentication,
  observability and writing plugins.

## 0.1.0-rc.1 (2026-11-21)

First version: a rewrite of NkSIP in Elixir, on Malla.

* **Core**: SIP (RFC 3261) with transactions, dialogs, proxies (stateless
  and stateful, with forking), SUBSCRIBE/NOTIFY and REFER; asynchronous
  routing; digest authentication with MD5, SHA-256 and SHA-512-256 (RFC 7616
  and RFC 8760); SDP offer/answer and WebRTC utilities.
* **Transports**: UDP, TCP, TLS, WS and WSS over IPv4 and IPv6, with
  RFC 3263 DNS.
* **Registration and NAT plugins**: `Caracola.Registrar` (with Path and
  Service-Route), `Caracola.Registrar.Cluster`, `Caracola.Outbound`,
  `Caracola.UACAutoOutbound`, `Caracola.UACAutoRegister`, `Caracola.Gruu`
  and `Caracola.Push`.
* **Call control plugins**: `Caracola.Rel100`, `Caracola.SessionTimers`,
  `Caracola.Refer`, `Caracola.Replaces`, `Caracola.Join`, `Caracola.B2BUA`,
  `Caracola.InfoPackages` and `Caracola.Siprec`.
* **Events and presence plugins**: `Caracola.EventCompositor`,
  `Caracola.Notifier`, `Caracola.Presence`, `Caracola.DialogInfo`,
  `Caracola.MessageWaiting`, `Caracola.Conference` and
  `Caracola.WatcherInfo`.
* **Security and load plugins**: `Caracola.AssertedIdentity`,
  `Caracola.StirShaken`, `Caracola.RateLimit` and
  `Caracola.OverloadControl`.
* **Routing**: `Caracola.Dispatcher` and `Caracola.History`.
* **Observability**: `:telemetry` events (`Caracola.Telemetry`) and HEP
  capture (`Caracola.HEP`).
* Guides, and two tutorials with their code in `examples/tutorial`.
* Interoperability and load tests with SIPp (`mix test --only sipp`,
  `mix test --only load`), FreeSWITCH (`--only freeswitch`), baresip
  (`--only baresip`) and Asterisk (`--only asterisk`).
