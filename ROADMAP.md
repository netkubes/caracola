# Roadmap

Caracola already covers the SIP core (RFC 3261), stateless and stateful
proxies, UDP/TCP/TLS/WS/WSS over IPv4 and IPv6, RFC 3263 DNS, digest
authentication (MD5, SHA-256 and SHA-512-256), SDP offer/answer and
SUBSCRIBE/NOTIFY, and has plugins for the registrar (also shared by the
nodes of a cluster), 100rel, session timers, REFER, Replaces, Join,
PUBLISH, automatic registration, SIP outbound, GRUU, presence, dialog
state, message waiting, conference state, rate limiting, overload
control, dispatcher, STIR/SHAKEN, push notifications, B2BUA, watcher
information, call history, INFO packages and session recording, and
captures to Homer with HEP. It is tested against SIPp, FreeSWITCH,
baresip and Asterisk, for interoperability and under load (see
[Interoperability and performance](guides/14-interoperability-and-performance.md)).

This document lists what is still missing for a modern, production SIP
stack. The *Kind* column says how each item would be built:

* **Plugin**: a Malla plugin, that hooks the request, response and dialog
  callbacks (as `Caracola.Refer` or `Caracola.Outbound`).
* **Core**: a change in Caracola itself.
* **Registrar**: an option or a storage backend of `Caracola.Registrar`.
* **Module**: functions without callbacks, or a separate library.

## Optional

| Feature | Kind | RFCs |
| --- | --- | --- |
| SCTP transport | Core | RFC 4168 |
| SIP over QUIC | Core | Not standardised yet |
| ENUM | Module | RFC 6116, in `Caracola.DNS` |
| MESSAGE with CPIM | Plugin | RFC 3862 |
| MSRP | Module | RFC 4975, better as a separate library |

The features already built, and their known limitations, are in the
[plugins guide](guides/10-plugins.md) and
[Interoperability and performance](guides/14-interoperability-and-performance.md#known-limitations).
