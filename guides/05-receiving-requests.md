# Receiving requests

Incoming requests go through the callbacks of the service. They are
implemented with `defcb`; callbacks you do not implement use the default
of `Caracola` (or of the plugins), and returning `:cont` from a clause
falls back to it.

All the callbacks run in the process of the call, receiving the request (a
`Caracola.Message`) and the call (a `Caracola.Call`, with the `service` and
its `config`). They must return quickly: a slow callback blocks every other
message of the same call.

## Processing steps

For each new request (not retransmissions, ACKs or CANCELs of existing
transactions), Caracola:

1. Checks it (Max-Forwards, loops, required extensions...).
2. Calls `sip_authorize(auth_list, req, call)` (see
   [Authentication](08-authentication.md)).
3. Calls `sip_route(scheme, user, domain, req, call)` with the parts of the
   Request-URI, to decide what to do with it.
4. If it is to be processed, calls the callback of its method:
   `sip_invite/2`, `sip_options/2`, `sip_register/2`, `sip_bye/2`,
   `sip_info/2`, `sip_message/2`, `sip_update/2`, `sip_subscribe/2`,
   `sip_notify/2`, `sip_refer/2`, `sip_publish/2`, `sip_prack/2`. A
   re-INVITE goes to `sip_reinvite/2` (which calls `sip_invite/2` by
   default), and a SUBSCRIBE refreshing a subscription to
   `sip_resubscribe/2`.

## Routing

`sip_route/5` returns:

* `:process` (the default) - process the request, statefully.
* `:process_stateless` - process it without a transaction (not for
  INVITE; the reply is
  sent once, and retransmissions are processed again).
* `{:reply, reply}` or `{:reply_stateless, reply}` - reply at once.
* `:proxy`, `{:proxy, uri_set}` or `{:proxy, uri_set, opts}` - proxy it
  statefully; and `:proxy_stateless`... to proxy it without state. See
  [Proxies](07-proxy.md).

```elixir
defcb sip_route(_scheme, nil, "example.com", _req, _call), do: :process
defcb sip_route(_scheme, user, "example.com", _req, call), do: {:proxy, locate(user, call)}
defcb sip_route(_scheme, _user, _domain, _req, _call), do: {:reply, :forbidden}
```

`user` is `nil` when the Request-URI has no user part.

## Replying

Method callbacks return `{:reply, reply}`, where `reply` is a status code,
`{code, opts}` or a shortcut, like `:ok`, `:busy`, `:decline`,
`{:redirect, contacts}` or `{:invalid_request, "Reason"}`. See
`Caracola.Reply` for all of them and the response options:

```elixir
defcb sip_options(_req, _call),
  do: {:reply, {:ok, [:allow, :supported, {:add, "x-version", "1.0"}]}}

defcb sip_message(req, _call) do
  IO.puts("Message: #{req.body}")
  {:reply, :ok}
end
```

### Replying later

A callback can return `:noreply` and reply from another process with
`Caracola.reply/2`, several times for provisional responses:

```elixir
defcb sip_invite(req, _call) do
  spawn(fn ->
    :ok = Caracola.reply(req, :ringing)
    sdp = MyMedia.answer(req.body)
    Caracola.reply(req, {:answer, sdp})
  end)

  :noreply
end
```

If no final response is sent, INVITE transactions are answered with a 408
after timer C (three minutes by default, `:timer_c`), and other requests
with a 408 after 64·T1 (32 seconds by default).

As a safety net, every call removes the transactions older than twice
`:trans_timeout` (15 minutes by default) and the dialogs without activity
for twice `:dialog_timeout`.

## Reading requests

The request is a `Caracola.Message`. The main headers are parsed into its
fields (`ruri`, `from`, `to`, `contacts`, `routes`, `vias`, `call_id`,
`cseq`, `expires`, `event`, `content_type`, `supported`, `require`...); the
others are in `headers`, and `Caracola.Message.header/2` returns the values
of any header by name:

```elixir
defcb sip_invite(req, _call) do
  agent = req |> Caracola.Message.header("user-agent") |> List.first()
  %Caracola.URI{user: caller} = req.from
  sdp = Caracola.SDP.from_message(req)
  ...
end
```

## Notifications

Some callbacks only notify, and their result is ignored:

* `sip_ack(req, call)` - the ACK of a 2xx response to INVITE.
* `sip_cancel(invite_req, cancel_req, call)` - an INVITE was cancelled;
  Caracola replies 487 to it.
* `sip_dialog_update(event, dialog, call)` and
  `sip_session_update(event, dialog, call)` - changes in dialogs and their
  sessions, see [Dialogs and subscriptions](06-dialogs-and-subscriptions.md).

## Defaults

| Callback | Default |
|---|---|
| `sip_authorize/3` | `:ok` |
| `sip_get_user_pass/4` | `false` (no users) |
| `sip_route/5` | `:process` |
| `sip_options/2` | 200 with Contact, Allow, Allow-Event, Accept and Supported |
| `sip_invite/2` | 603 Decline |
| `sip_reinvite/2` | calls `sip_invite/2` |
| `sip_register/2` | 405 (the registrar plugin processes them) |
| `sip_bye/2` | 200 |
| `sip_info/2` | 200 |
| `sip_message/2` | 603 Decline |
| `sip_update/2` | 603 Decline |
| `sip_subscribe/2` | 603 Decline |
| `sip_resubscribe/2` | 200 |
| `sip_notify/2` | 200 |
| `sip_unsolicited_notify/2` | 481 (NOTIFYs outside of any subscription) |
| `sip_refer/2` | 603 (the refer plugin processes them) |
| `sip_publish/2` | 405 (the event compositor plugin processes them) |
| `sip_prack/2` | 200 |

The list of callbacks and their arguments is in the documentation of the
`Caracola` module.
