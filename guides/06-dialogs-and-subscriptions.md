# Dialogs and subscriptions

## Dialogs

A dialog is a peer-to-peer relationship between two user agents, created by
a response to an INVITE (101-299) or a 2xx response to a SUBSCRIBE, REFER
or NOTIFY. Caracola creates, updates and removes dialogs automatically;
they live in the process of their call.

Dialogs are identified by a handle, `{:dialog, service, call_id, id}`:

* Responses to INVITE return it as their first meta:
  `{:ok, 200, [dialog: dialog]}`.
* `Caracola.Dialog.handle/1` returns the handle of the dialog of any
  in-dialog request or response, as the ones received in callbacks.
* `Caracola.Dialog.list/2` returns the dialogs of a call.

With the handle you send in-dialog requests (`Caracola.UAC.bye(dialog)`),
get its current state (`Caracola.Dialog.get/1`, a `Caracola.Dialog` struct)
or remove it without sending anything (`Caracola.Dialog.stop/1`; to hang
up, send a BYE).

```elixir
{:ok, %Caracola.Dialog{invite: invite, route_set: routes}} = Caracola.Dialog.get(dialog)
```

### The INVITE usage

The `invite` field of the dialog (`Caracola.Dialog.Invite`) has the state
of the INVITE session: its `status` (`:proceeding_uac`, `:proceeding_uas`,
`:accepted_uac`, `:accepted_uas`, `:confirmed` or `:bye`) and the current
`local_sdp` and `remote_sdp`.

Caracola takes care of:

* Retransmitting the 2xx response until the ACK arrives, and sending a BYE
  if it does not.
* Re-INVITEs and UPDATEs, with offer/answer (RFC 3264) and glare (491).
* Target refresh (the Contact of re-INVITEs and UPDATEs).
* The dialog timeout (`:dialog_timeout`, 30 minutes by default): without
  activity the dialog is ended with a BYE. With session timers, the
  negotiated interval is used instead (see `Caracola.SessionTimers`).
* Ending dialogs on BYE or on responses that end them (RFC 5057).

### Notifications

Changes are notified to the service with the callbacks:

* `sip_dialog_update(event, dialog, call)`, where `event` is `:start`,
  `{:invite_status, status}` (`{:invite_status, {:stop, reason}}` when the
  INVITE usage ends), `:target_update`, `:invite_timeout`,
  `{:invite_refresh, sdp}` (session timers), `{:subscription_status,
  status, subscription}` or `:stop`.
* `sip_session_update(event, dialog, call)`, with `{:start, local_sdp,
  remote_sdp}` when the first offer/answer completes, `{:update, local_sdp,
  remote_sdp}` when it changes, and `:stop`.

```elixir
defcb sip_session_update({:start, local, remote}, _dialog, _call) do
  MyMedia.start(local, remote)
  :ok
end

defcb sip_session_update(_event, _dialog, _call), do: :ok
```

### Authorized origins

The addresses that sent or received a 2xx response in a dialog are
authorized in it: later requests of the dialog coming from them get
`:dialog` in the authorization list of `sip_authorize/3` (see
[Authentication](08-authentication.md)). `Caracola.Dialog.authorized/1`
lists them and `Caracola.Dialog.clear_authorized/1` removes them.

## Offer and answer

SDP bodies are parsed and generated with `Caracola.SDP`:

```elixir
sdp = Caracola.SDP.new("10.0.0.1", [{"audio", 4000, [{:rtpmap, 0, "PCMU/8000"}, :sendrecv]}])
{:ok, 200, [dialog: dialog]} = Caracola.UAC.invite(MyUA, uri, body: sdp)
```

`Caracola.SDP.from_message/1` returns the SDP of a request or response (or
`nil`), `Caracola.SDP.increment/1` increments its version, and
`Caracola.SDP.update/2` changes the direction of its medias (`:sendonly`,
`:recvonly`, `:inactive`, `:sendrecv`). For WebRTC (ICE, DTLS-SRTP,
BUNDLE and codecs) see `Caracola.SDP.WebRTC`.

The offer can be in the INVITE and the answer in the response (2xx, or a
reliable provisional response with `Caracola.Rel100`), or the offer in the
response and the answer in the ACK (or PRACK). UPDATE can change the
session before the call is answered.

## Subscriptions

SUBSCRIBE and NOTIFY (RFC 6665) create subscriptions inside dialogs (a
dialog can have several, and an INVITE usage). They are identified by a
handle, `{:subscription, service, call_id, dialog_id, id}`, returned by 2xx
responses to SUBSCRIBE: `{:ok, 200, [subscription: subscription]}`.

The services must list the event packages they accept in the `:events` of
the configuration; requests for other events get a 489.

### Subscriber

```elixir
{:ok, 200, [subscription: subs]} =
  Caracola.UAC.subscribe(MyUA, "sip:bob@example.com", event: "presence", expires: 600)

# Refreshes it
Caracola.UAC.subscribe(subs, expires: 600)

# Ends it
Caracola.UAC.subscribe(subs, expires: 0)
```

NOTIFYs reach `sip_notify/2`, and changes of the subscription
`sip_dialog_update({:subscription_status, status, subscription}, dialog,
call)`, where `status` is `:init`, `:pending`, `:active`, `:middle_timer`
(half of the expiration time: a good moment to refresh it) or
`{:terminated, reason}`.

### Notifier

New subscriptions reach `sip_subscribe/2`, and refreshes
`sip_resubscribe/2`. The notifier sends NOTIFYs with the subscription
handle and a Subscription-State:

```elixir
defcb sip_subscribe(req, _call) do
  subs = Caracola.Subscription.handle_of(req)

  spawn(fn ->
    Caracola.UAC.notify(subs, body: presence(), subscription_state: :active)
  end)

  {:reply, :ok}
end
```

`subscription_state:` is `:active`, `:pending`, `{:active, expires}` or
`{:terminated, reason}` (`:deactivated`, `:probation`, `:rejected`,
`:timeout`, `:giveup`, `:noresource` or `:invariant`). See
`Caracola.Subscription`.

Subscriptions expire if they are not refreshed, and end with a NOTIFY with
`{:terminated, reason}` or with responses that end them.

For event packages whose state is a document (presence, dialog state,
message waiting...), the `Caracola.Notifier` plugin does all this: it keeps
the watchers of each resource and sends them the state when they
subscribe, refresh, and whenever it changes. `Caracola.Presence` and
`Caracola.DialogInfo` are built on it.

### Unsolicited notifications

Many PBXs, as Asterisk, send message waiting (`message-summary`) NOTIFYs
to registered phones without any subscription. RFC 6665 requires a 481 for
them, and that is what Caracola replies by default. A service that wants
them implements `sip_unsolicited_notify/2`, with the same results as
`sip_notify/2`; accepting one creates no dialog:

```elixir
defcb sip_unsolicited_notify(req, _call) do
  if match?({"message-summary", _}, req.event) do
    MyApp.message_waiting(req.from, req.body)
    {:reply, :ok}
  else
    :cont
  end
end
```

NOTIFYs of a REFER without the `id` parameter (as the ones of Asterisk)
belong to the first REFER of their dialog (RFC 3515 §2.4.6).

## Other event packages

* REFER creates an implicit subscription to the `refer` event, see
  `Caracola.Refer`.
* PUBLISH (RFC 3903) is processed by `Caracola.EventCompositor`.
* `presence` (RFC 3856), with PIDF documents, by `Caracola.Presence`.
* `dialog` (RFC 4235), for busy lamp fields, by `Caracola.DialogInfo`.
