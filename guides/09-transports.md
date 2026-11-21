# Transports

## Listeners

The `:listen` option of the configuration has the listening addresses, as
URIs:

| URI | Listeners |
|---|---|
| `sip:all:5060` | UDP and TCP on port 5060, all IPv4 interfaces |
| `sip:127.0.0.1:5060` | UDP and TCP on 127.0.0.1 |
| `<sip:all:5060;transport=tcp>` | only TCP |
| `<sip:all:5061;transport=tls>`, `sips:all:5061` | TLS |
| `<sip:all:8080;transport=ws>` | WebSocket |
| `<sip:all:8443/sip;transport=wss>` | secure WebSocket, only for the `/sip` path |
| `sip:[::1]:5060`, `sip:all6:5060` | IPv6 |
| `sip:all:0` | a random port |

Without port, the default of the transport is used (5060, 5061 for TLS, 80
for WS and 443 for WSS). UDP listeners always listen on TCP on the same
port, as RFC 3261 requires.

`Caracola.listeners/1` returns the listeners of a service.

## Connections

TCP, TLS, WS and WSS connections are kept in a table and reused to send to
the same address, in both directions: a connection opened by a client is
used to send requests back to it. They are closed after three minutes
without traffic (`idle_timeout:` option of the requests).

Responses go back through the connection the request came from or, over
UDP, to the address and port the request came from (`rport`, RFC 3581).

Requests over UDP larger than `:udp_max_size` (1300 bytes by default) are
sent over TCP.

## TLS

TLS listeners need a certificate, in the `:tls` option of the
configuration (`:ssl` options):

```elixir
sip: [
  listen: "sip:all:5060, <sip:all:5061;transport=tls>",
  tls: [certfile: "priv/cert.pem", keyfile: "priv/key.pem"]
]
```

Outgoing TLS connections verify the server certificate against the system
CAs and, when the destination is a host name, check the name. The
`:tls_client` option of the configuration (or `tls:` of the request) adds
`:ssl` options: `cacerts`, `verify`...

`sips` URIs are sent over TLS (or WSS).

## WebSocket

SIP over WebSocket (RFC 7118) uses the `sip` subprotocol, and each SIP
message travels in a WebSocket message. WS and WSS listeners accept any
HTTP path, or only the one in the listen URI. Outgoing connections use the
path of the destination URI (`<sip:example.com/ws;transport=ws>`), or `/`.

WSS needs `:tls` options, as TLS.

Browsers can not receive connections, so a SIP server must reach them
through the connection they registered from; use `Caracola.Outbound` in the
registrar.

`Caracola.SDP.WebRTC` has the SDP utilities of WebRTC endpoints: ICE
credentials and candidates (with the trickle ICE bodies of RFC 8840),
DTLS-SRTP fingerprint and setup, BUNDLE, rtcp-mux, and codec filtering.
For example, to send the candidates a browser gathers after the offer in
a trickle ICE INFO:

```elixir
alias Caracola.SDP.WebRTC

body = WebRTC.sdpfrag(local_sdp, [%{candidate: candidate, mid: mid, index: index}])

Caracola.UAC.info(dialog, [
  {:add, "info-package", "trickle-ice"},
  body: body,
  content_type: WebRTC.sdpfrag_content_type()
])
```

## IPv6

Listeners on IPv6 addresses send and receive over IPv6. A service listening
on both IPv4 and IPv6 can proxy between them: its Record-Route is rewritten
in each response with the address it is sent from (RFC 5118), so each side
of the dialog gets an address it can reach.

## Hosts in headers

Via, Contact, Record-Route and Path headers use the IP of the listener or,
for listeners on all interfaces, the main IP of the machine. `:local_host`
and `:local_host6` set the host to use (a name or another address, as the
public address behind a NAT).

## DNS

Destinations are resolved following RFC 3263: NAPTR records to choose the
transport, SRV records for the hosts and ports, and A/AAAA records, with a
cache. Each address is tried in order until one works. See `Caracola.DNS`.

## Keepalives

TCP and TLS connections answer CRLF keepalives (RFC 5626), and UDP
listeners answer STUN Binding requests on the SIP port.
`Caracola.UACAutoOutbound` sends them to keep the flows of its
registrations alive.
