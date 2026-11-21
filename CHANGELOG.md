# Changelog

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
