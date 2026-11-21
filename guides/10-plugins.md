# Plugins

SIP extensions are Malla plugins. A service lists them in `:plugins`; they
all depend on `Caracola`, which does not need to be listed then. Each
plugin adds its methods to Allow and its option tags to Supported.

```elixir
defmodule MyServer do
  use Malla.Service,
    plugins: [Caracola.Registrar, Caracola.Rel100, Caracola.SessionTimers],
    sip: [listen: "sip:all:5060"],
    registrar: [min_time: 60]
end
```

The plugins, by area:

**Registration and NAT**

| Plugin | RFC | What it does |
|---|---|---|
| `Caracola.Registrar` | 3261 §10, 3327 | Registrar server, with Path |
| `Caracola.Registrar.Cluster` | | Registrar shared by the nodes of a Malla cluster |
| `Caracola.Outbound` | 5626 | SIP outbound: flows through NATs |
| `Caracola.UACAutoOutbound` | 5626 | Automatic registrations with outbound and keepalives |
| `Caracola.UACAutoRegister` | | Automatic registrations and pings |
| `Caracola.Gruu` | 5627 | Globally routable UA URIs |
| `Caracola.Push` | 8599 | Push notifications to wake up mobile devices |

**Call control**

| Plugin | RFC | What it does |
|---|---|---|
| `Caracola.Rel100` | 3262 | Reliable provisional responses (100rel, PRACK) |
| `Caracola.SessionTimers` | 4028 | Session timers |
| `Caracola.Refer` | 3515 | REFER, call transfer |
| `Caracola.Replaces` | 3891 | Replaces: attended transfer, call pickup |
| `Caracola.Join` | 3911 | Join: barge-in, conferences |
| `Caracola.B2BUA` | | Back-to-back user agent: bridges an incoming call with a new one |
| `Caracola.InfoPackages` | 6086 | INFO packages: `Recv-Info` and `Info-Package` |
| `Caracola.Siprec` | 7866, 7865 | Session recording (SIPREC): recording sessions and metadata |

**Events and presence**

| Plugin | RFC | What it does |
|---|---|---|
| `Caracola.EventCompositor` | 3903 | PUBLISH, event state compositor |
| `Caracola.Notifier` | 6665 | Base of event packages: watchers and NOTIFYs of a resource |
| `Caracola.Presence` | 3856, 3863 | Presence server with PIDF documents |
| `Caracola.DialogInfo` | 4235 | Dialog state (`dialog-info`), for busy lamp fields |
| `Caracola.MessageWaiting` | 3842 | Message waiting indication (`message-summary`) |
| `Caracola.Conference` | 4575 | Conference state (`conference-info`) |
| `Caracola.WatcherInfo` | 3857, 3858 | Watcher information (`presence.winfo`): pending watchers |

**Security and load**

| Plugin | RFC | What it does |
|---|---|---|
| `Caracola.AssertedIdentity` | 3325, 3323 | P-Asserted-Identity in a trust domain, privacy |
| `Caracola.StirShaken` | 8224, 8225, 8588 | Caller identity signing and verification (STIR/SHAKEN) |
| `Caracola.RateLimit` | | Rate limits, bans of scanners and brute-force attempts |
| `Caracola.OverloadControl` | 7339 | Overload control: servers ask clients to send less |

**Routing**

| Plugin | RFC | What it does |
|---|---|---|
| `Caracola.Dispatcher` | | Destination groups: load balancing, health checks, failover |
| `Caracola.History` | 7044, 5806 | History-Info and Diversion: why a request was retargeted |

**Observability**

| Plugin | RFC | What it does |
|---|---|---|
| `Caracola.HEP` | | HEPv3 capture of the messages, to Homer |

The documentation of each module describes its configuration, functions
and callbacks. A short overview, by area:

## Registrar

Answers REGISTER requests, storing the contacts of each address-of-record
(in memory, or in your storage with `sip_registrar_store/2`). Contacts are
found with `Caracola.Registrar.find/4` and `Caracola.Registrar.qfind/4`, to
proxy requests to them. Requests from registered contacts get `:register`
in the authorization list. Configuration: `registrar: [min_time:,
max_time:, default_time:, service_route:]`; with `:service_route`, the
2xx responses carry a Service-Route header (RFC 3608), that
`Caracola.UACAutoRegister.service_route/2` returns to the registered UAs
as the routes for their requests.

With `Caracola.Registrar.Cluster` instead, the registrations are shared by
all the nodes of a `global: true` service: each change is sent to the
other nodes (the last one wins), and nodes merge the registrations of
another one when they start and periodically.

## Automatic registrations

`Caracola.UACAutoRegister.start_register/4` registers a service and keeps
the registration refreshed; `Caracola.UACAutoRegister.start_ping/4` sends
OPTIONS periodically. Changes are notified with
`sip_uac_auto_register_updated_reg/3` and
`sip_uac_auto_register_updated_ping/3`.

## Outbound

`Caracola.Outbound` implements RFC 5626 for user agents, edge proxies and
registrars: requests for a registered user agent go through the same
connection (flow) it registered from. `Caracola.UACAutoOutbound` registers
with outbound, keeps the flows alive with CRLF (TCP, TLS) or STUN (UDP)
keepalives, and registers again when they fail.

## GRUU

With `Caracola.Gruu`, the registrar gives a public and a temporary GRUU to
each registered instance, and `Caracola.Gruu.registrar_find/2` finds the
contacts of a GRUU.

## Push notifications

`Caracola.Push` extends the registrar for mobile devices registering with
push parameters (`pn-provider`, `pn-prid`, `pn-param`).
`Caracola.Push.route/3` routes a request to the registered contacts and,
for the ones with push, first sends a push notification with
`sip_push_send/3` (implemented by the service, which talks to APNs or FCM)
and waits for the device to register again:

```elixir
use Malla.Service, plugins: [Caracola.Push], push: [providers: ["apns", "fcm"]]

defcb sip_route(_scheme, _user, "example.com", req, call),
  do: Caracola.Push.route(req, call, [:record_route])

defcb sip_push_send(push, _req, _service),
  do: MyApp.Apns.send(push.prid, push.param)
```

## Reliable provisional responses

With `Caracola.Rel100`, provisional responses are sent reliably when the
request requires it, or with the `:rel_ringing` and `:rel_session_progress`
replies, and retransmitted until the PRACK arrives. As client, the PRACKs
are sent automatically.

## Session timers

With `Caracola.SessionTimers`, sessions are refreshed periodically
(re-INVITE or UPDATE), and ended if they are not. The refresher gets
`{:invite_refresh, sdp}` in `sip_dialog_update/3` at half the interval, and
can refresh the session with `Caracola.UAC.refresh/2`. Configuration:
`sip: [session_expires: 1800, min_se: 90]`.

## Refer

`Caracola.UAC.refer/3` with `refer_to: uri` asks the other party to send a
request. With `Caracola.Refer`, an incoming REFER is accepted if
`sip_refer(refer_to, req, call)` returns `true`, and the progress of the
INVITE is notified to the referrer, which gets it in
`sip_refer_update(subscription, status, call)`.

## Replaces

With `Caracola.Replaces`, a new INVITE with a Replaces header for an
existing dialog of the service is checked (481, 486 or 603 if it cannot
replace it), and once the new dialog is confirmed the replaced one is ended
with a BYE (or a CANCEL, if it was an early dialog of ours). For attended
transfers, `Caracola.Replaces.refer_to/2` builds the Refer-To of a REFER,
and `Caracola.Replaces.header/1` the header of an INVITE.

## Join

With `Caracola.Join`, a new INVITE with a Join header for an existing
dialog of the service is checked the same way (481, 603 or 400), and
`Caracola.Join.joined/1` gives the application the dialog to join it to;
mixing the sessions is up to it. `Caracola.Join.refer_to/2` asks a third
party to join a call.

## INFO packages

With `Caracola.InfoPackages` (RFC 6086) and `info_packages: ["dtmf"]`, the
INVITEs of the service and their responses say in `Recv-Info` which
packages it accepts, INFOs of those packages go to
`sip_info_package/3`, and the others get a 469.
`Caracola.InfoPackages.send/4` sends an INFO of a package the remote side
accepts. INFOs without package work as before.

## B2BUA

`Caracola.B2BUA` bridges an incoming INVITE with a new one, sent from the
service: unlike a proxy, the service is an endpoint of both dialogs, so
it sees and can change everything (topology hiding, SDP changes for a
media relay, call control). `Caracola.B2BUA.bridge/3` is a result for
`sip_invite/2`:

```elixir
use Malla.Service, plugins: [Caracola.B2BUA], sip: [listen: "sip:all:5060"]

defcb sip_invite(req, _call),
  do: Caracola.B2BUA.bridge(req, "sip:bob@10.0.0.2", copy_headers: ["p-asserted-identity"])

defcb sip_b2bua_sdp(sdp, _from, _bridge), do: MyApp.MediaRelay.rewrite(sdp)
```

Responses, BYEs, re-INVITEs, UPDATEs, INFOs and CANCELs go from one leg to
the other, and `sip_b2bua_update/2` tells when the call is answered and
when it ends (for billing, for example). `Caracola.B2BUA.hangup/2` ends a
call.

## Session recording

`Caracola.Siprec` (RFC 7866) starts recording sessions with a recording
server: `Caracola.Siprec.record/4` sends an INVITE with the SDP of the
streams and the metadata (RFC 7865) of the participants, and
`Caracola.Siprec.bridge/2` builds them for a call of `Caracola.B2BUA`.
Copying the media to the recorder is up to the application. As recording
server, `Caracola.Siprec.recording_session?/1` and
`Caracola.Siprec.decode/1` read them.

## Event compositor

With `Caracola.EventCompositor`, PUBLISH requests are stored by
address-of-record and entity tag, and found with
`Caracola.EventCompositor.find/3` and `Caracola.EventCompositor.list/3`.

## Event packages

`Caracola.Notifier` is the base of the event packages whose state is a
body: it accepts the SUBSCRIBEs of a resource (the AOR of the
Request-URI), after `sip_notifier_authorize/4`, and sends a NOTIFY with the
current state when they arrive, with each refresh, and whenever
`Caracola.Notifier.notify/4` is called, in order and with a growing
version for each subscription. A package plugin adds its events with
`Caracola.Notifier.add_events/2` and builds the body in
`sip_notifier_body/4`.

`Caracola.Presence` (RFC 3856) is a presence server: PUBLISH requests of
the `presence` event are stored by the event compositor, and each change
is notified to the watchers of the presentity, with the composite PIDF
document of its publications. `Caracola.Presence.encode/3` and
`Caracola.Presence.decode/1` build and read PIDF documents.

`Caracola.DialogInfo` (RFC 4235) notifies the `dialog` event: the INVITE
dialogs of the service whose local URI has the AOR, and the ones set with
`Caracola.DialogInfo.put/3`, as phones need for their busy lamp fields.

`Caracola.MessageWaiting` (RFC 3842) notifies the `message-summary` event
with the summary of a mailbox set with `Caracola.MessageWaiting.put/3`
(new and old messages of each class), and `Caracola.Conference` (RFC
4575) the `conference` event, with the description and users of a
conference set with `Caracola.Conference.put_description/3`,
`Caracola.Conference.put_user/3` and `Caracola.Conference.remove_user/3`.
Both have `encode` and `decode` functions for their bodies.

`sip_notifier_authorize/4` can also answer `:pending`: the watcher gets
no state until it is authorized with `Caracola.Notifier.approve/1` (or
rejected with `Caracola.Notifier.terminate/2`). With
`Caracola.WatcherInfo` (RFC 3857 and RFC 3858), the presentity subscribes
to `presence.winfo` to see its watchers and their status, and decide.

```elixir
defmodule MyPBX do
  use Malla.Service,
    plugins: [Caracola.Registrar, Caracola.Presence, Caracola.DialogInfo],
    sip: [listen: "sip:all:5060"]
end
```

## Asserted identity

With `Caracola.AssertedIdentity`, P-Asserted-Identity headers of requests
received from outside the trust domain (the `:trusted` addresses) are
removed before the request is authorized or routed, so
`Caracola.AssertedIdentity.identities/1` only returns trusted identities.
A proxy asserts the identity of an authenticated user with
`Caracola.AssertedIdentity.assert_opts/1`, and honours `Privacy: id` when
forwarding outside the trust domain with
`Caracola.AssertedIdentity.forward_opts/2`.

## STIR/SHAKEN

`Caracola.StirShaken` signs calls with an `Identity` header (a PASSporT
signed with ES256) and verifies the ones received: the signature, the
certificate chain, the age and the numbers. The application chooses the
attestation level when signing, with
`Caracola.StirShaken.sign_opts/3`, and either verifies with
`Caracola.StirShaken.verify/2` or lets the plugin reject the INVITEs that
fail (`enforce: :invalid` or `:all`).

```elixir
use Malla.Service,
  plugins: [Caracola.StirShaken],
  stir_shaken: [
    key: File.read!("priv/shaken_key.pem"),
    x5u: "https://cert.example.com/shaken.pem",
    verify: [trusted: [File.read!("priv/sti_ca.pem")], enforce: :invalid]
  ]

defcb sip_route(_scheme, _user, _domain, req, call),
  do: {:proxy, :ruri, Caracola.StirShaken.sign_opts(call.service, req, attest: "A")}
```

## Rate limiting

`Caracola.RateLimit` checks every request in the transport process, before
a call process is started for it: requests from banned addresses are
dropped, scanners (by their `User-Agent`) are banned, and requests over the
limits per address (`:per_ip`) or per user (`:per_user`) are rejected with
a 503. Addresses with too many failed authentications are banned too.

```elixir
use Malla.Service,
  plugins: [Caracola.RateLimit, Caracola.Registrar],
  rate_limit: [per_ip: {50, 1000}, auth_failures: {5, 60_000}, exempt: ["10.0.0.0/8"]]
```

## Overload control

With `Caracola.OverloadControl` (RFC 7339), a server tells the clients
that support it (with `oc` in their Via) the percentage of requests they
should stop sending, from the number of calls of the service or set with
`Caracola.OverloadControl.set_loss/3`, and as client the service stops
sending that percentage of new requests to overloaded servers. Together
with `Caracola.RateLimit`, which protects the service from abusive
clients.

## Dispatcher

`Caracola.Dispatcher` keeps groups of destinations, checked with OPTIONS
requests, and `Caracola.Dispatcher.route/4` proxies a request to the ones
that are up, one after another, in the order of the group strategy
(`:priority`, `:round_robin`, `:weighted` or `:hash`):

```elixir
use Malla.Service,
  plugins: [Caracola.Dispatcher],
  dispatcher: [groups: [gws: [destinations: ["sip:10.0.0.1", "sip:10.0.0.2"], strategy: :round_robin]]]

defcb sip_route(_scheme, _user, _domain, req, call),
  do: Caracola.Dispatcher.route(:gws, req, call, [:record_route])
```

## History

`Caracola.History` adds the `History-Info` (RFC 7044) and `Diversion`
(RFC 5806) headers when a proxy retargets a request, so the final
destination (a voicemail, a forwarded phone) knows who the call was
for and why it got there. It is a helper, not a plugin to list in
`:plugins`: `Caracola.History.retarget/3` is a `sip_route/5` result.

```elixir
defcb sip_route(_scheme, "alice", "example.com", req, _call) do
  if MyApp.forwarding?("alice"),
    do: Caracola.History.retarget(req, ["sip:voicemail@example.com"], cause: 302),
    else: :proxy
end
```

`Caracola.History.entries/1` and `Caracola.History.diversions/1` read the
headers of a received request.

## HEP capture

`Caracola.HEP` sends every SIP message received or sent by the service to
a capture server (Homer, heplify-server) with HEPv3 over UDP, using the
telemetry events of [Observability](11-observability.md). Configure it
under the `:hep` key with `:host`, `:port`, `:capture_id` and `:password`.

## Writing plugins

See [Writing plugins](12-writing-plugins.md).
