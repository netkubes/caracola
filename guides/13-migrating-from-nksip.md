# Migrating from NkSIP

Caracola keeps the design, concepts and most of the behaviour of NkSIP:
services with callbacks, a process per call, sip replies, the same UAC
options and plugins. This guide lists the equivalences and the differences.

## Services

NkSIP services were started with `nksip:start/2`, a name, a callback
module and a map of options. In Caracola a service is a module using
`Malla.Service`, with its callbacks in the same module:

```erlang
%% NkSIP
nksip:start(server, #{
    callback => my_callbacks,
    plugins => [nksip_registrar],
    sip_listen => "sip:all:5060",
    sip_from => "sip:server@example.com",
    sip_registrar_min_time => 60
}).
```

```elixir
# Caracola
defmodule MyServer do
  use Malla.Service,
    plugins: [Caracola.Registrar],
    sip: [listen: "sip:all:5060", from: "sip:server@example.com"],
    registrar: [min_time: 60]

  # callbacks...
end

MyServer.start_link()
```

| NkSIP | Caracola |
|---|---|
| `nksip:start(Name, Opts)` | `MyService.start_link(config)` |
| `nksip:stop(Name)` | `MyService.stop()` |
| `nksip:update(Name, Opts)` | Malla's reconfiguration |
| Service id (atom) | The service module |
| `nkserver:get/put` | Your own state, or Malla's config |

## Configuration

The `sip_*` options go under `sip:`, without the prefix
(`sip_listen` → `listen`, `sip_local_host` → `local_host`,
`sip_timer_t1` → `timer_t1`, `sip_no_100` → `no_100`, `sip_events` →
`events`...). See `Caracola.Config`.

Plugin options go under their own key:

| NkSIP | Caracola |
|---|---|
| `sip_registrar_min_time`, `_max_time`, `_default_time` | `registrar: [min_time:, max_time:, default_time:]` |
| `sip_event_compositor_default_expires` | `event_compositor: [default_expires:]` |
| `sip_uac_auto_register_timer` | `uac_auto_register: [timer:]` |
| `sip_uac_auto_outbound_all_fail`, `_any_ok`, `_max_time`, `_default_udp_ttl`, `_default_tcp_ttl` | `uac_auto_outbound: [all_fail:, any_ok:, max_time:, udp_ttl:, tcp_ttl:]` |
| `sip_session_expires`, `sip_min_se` | `sip: [session_expires:, min_se:]` |

## Plugins

| NkSIP | Caracola |
|---|---|
| `nksip_registrar` | `Caracola.Registrar` |
| `nksip_100rel` | `Caracola.Rel100` |
| `nksip_timers` | `Caracola.SessionTimers` |
| `nksip_refer` | `Caracola.Refer` |
| `nksip_event_compositor` | `Caracola.EventCompositor` |
| `nksip_uac_auto_register` | `Caracola.UACAutoRegister` |
| `nksip_outbound` | `Caracola.Outbound` |
| `nksip_uac_auto_outbound` | `Caracola.UACAutoOutbound` |
| `nksip_gruu` | `Caracola.Gruu` |
| `nksip_uac_auto_auth` | Built in: the `password:` option |
| `nksip_trace` | `Caracola.Telemetry.trace/1` |
| `nksip_stats`, `nksip_debug` | `:telemetry` events, see `Caracola.Telemetry` |

## Callbacks

Callbacks have the same names and arguments, and are defined with
`defcb`. Return values are the same, as atoms and tuples:
`{reply, ok}` → `{:reply, :ok}`, `noreply` → `:noreply`,
`{proxy, UriSet, Opts}` → `{:proxy, uri_set, opts}`, `continue` → `:cont`.

* In `sip_route/5`, a Request-URI without user gives `nil`, not `<<>>`.
* Authorization lists are the same: `dialog` → `:dialog`, `register` →
  `:register`, `{{digest, Realm}, true}` → `{{:digest, realm}, true}`.
* `sip_dialog_update/3` and `sip_session_update/3` get the dialog struct
  (`Caracola.Dialog`), not a handle; `Caracola.Dialog.handle/1` returns its
  handle.
* Plugin callbacks: `sip_refer/3` and `sip_refer_update/3`, and
  `sip_uac_auto_register_updated_reg/3` and
  `sip_uac_auto_register_updated_ping/3`, which get `(id, ok, service)`
  instead of `(service, id, ok)`.

## Requests and replies

`nksip_request` and `nksip_response` functions read messages, that are
now `Caracola.Message` structs: use their fields (`req.body`, `req.from`,
`req.call_id`...) and `Caracola.Message.header/2`.

| NkSIP | Caracola |
|---|---|
| `nksip_uac:invite(Srv, Uri, Opts)` | `Caracola.UAC.invite(service, uri, opts)` |
| `nksip_uac:bye(DialogId, Opts)` | `Caracola.UAC.bye(dialog, opts)` |
| `nksip_uac:ack(DialogId, Opts)` | `Caracola.UAC.ack(dialog, opts)` |
| `nksip_uac:cancel(ReqId, Opts)` | `Caracola.UAC.cancel(handle, opts)` |
| `nksip_request:reply(Reply, ReqId)` | `Caracola.reply(req, reply)` |
| `nksip_request:body(Req)` | `req.body` |
| `nksip_request:header(Name, Req)` | `Caracola.Message.header(req, name)` |
| `nksip_request:get_handle(Req)` | Not needed: `Caracola.reply/2` takes the request |
| `nksip_dialog:get_meta(invite_status, D)` | `Caracola.Dialog.get(dialog)` and its `invite.status` |
| `nksip_dialog:get_all(Srv, CallId)` | `Caracola.Dialog.list(service, call_id)` |
| `nksip_subscription:*` | `Caracola.Subscription` |
| `nksip_sdp:new/2`, `nksip_sdp:is_sdp/1` | `Caracola.SDP.new/2`, `Caracola.SDP.from_message/1` |
| `nksip_registrar:find/4` | `Caracola.Registrar.find/4` |
| `nksip_registrar_util:clear()` | `Caracola.Registrar.clear(service)` |

UAC options are the same, as Elixir terms: `{get_meta, [reason_phrase]}`
→ `get_meta: [:reason_phrase]`, `{add, "x-h", V}` → `{:add, "x-h", v}`,
`auto_2xx_ack` → `:auto_2xx_ack`. `sip_pass` is now `password:`. Header
names are strings (always lowercase in metas).

Callbacks of `:async` requests get `{:resp, code, resp}`, `{:req, req}`
and `{:error, reason}`, without the call.

Handles of dialogs, subscriptions and requests are tuples
(`{:dialog, service, call_id, id}`), not binaries.

## Differences

Most of the behaviour is the same, and the NkSIP test suite has been
ported. These are the known differences:

* **Proxies do not keep dialogs.** NkSIP proxies tracked the dialogs they
  recorded the route of. In Caracola a proxy only stays in the path: in-dialog
  requests through a proxy are authorized by `:register` or by digest,
  not by `:dialog`.
* `strict_proxy` and the recovery of the Request-URI after a strict router
  are not supported.
* Early dialogs last until timer C and end without a BYE, and a final
  non-2xx response ends all the early dialogs of the INVITE.
* `Caracola.Registrar.qfind/4` returns the groups with the highest `q`
  first (RFC 3261 §16.6); NkSIP returned the lowest first.
* Proxies require Path support only for REGISTER requests.
* With session timers, the side that does not refresh sends the BYE at
  `se - min(32, se / 3)` seconds (RFC 4028 §10), not at 3/4 of the interval.
* A challenged BYE does not end the dialog, so it can be sent again with
  credentials.
* REFER is accepted with a 202 (NkSIP used 200).
* Automatic registrations are refreshed before they expire (5 seconds or
  10% before), not when they expire.
* Outbound flow tokens are signed (HMAC), and temporary GRUUs encrypted
  with a random IV.
* `Caracola.UACAutoOutbound.get_registers/1` returns `{id, ok, next,
  fails}`, as NkSIP; `Caracola.UACAutoRegister.get_registers/1` returns
  `{id, ok, next}`.
* NOTIFYs outside of any subscription can be accepted with
  `sip_unsolicited_notify/2` (481 by default); NOTIFYs of a REFER without
  `id` belong to its first REFER; and a 2xx to SUBSCRIBE without Event is
  accepted.
* SCTP is not supported.
* Logging uses `Logger`, and metrics `:telemetry`.
