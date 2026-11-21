# Sending requests

Requests are sent with `Caracola.UAC`. There is a function per method
(`options/3`, `invite/3`, `register/3`, `subscribe/3`, `notify/3`,
`message/3`, `info/3`, `update/3`, `refer/3`, `publish/3`, `bye/3`), and
`Caracola.UAC.request/4` for any method.

```elixir
Caracola.UAC.options(MyUA, "sip:sip.example.com", opts)
Caracola.UAC.request(MyUA, "MESSAGE", "sip:bob@example.com", body: "Hi")
```

## Destination

The destination is a URI, as a string or a `Caracola.URI`. Write it between
`<` and `>` when it has URI parameters: `"<sip:host;transport=tcp>"`.
Without them, the parameters would belong to the header, not to the URI.

The request is sent to the first route (the `:route` option, or the
`:route` of the service configuration) or, without routes, to the
Request-URI. The transport, address and port are resolved following RFC
3263 (NAPTR, SRV and A/AAAA records), trying each address in order until
one works. The service needs a listener for the transport used: a service
listening only on UDP can not send over TLS.

## Results

By default, the call blocks until the final response arrives and returns
`{:ok, code, metas}`:

```elixir
{:ok, 200, []} = Caracola.UAC.options(MyUA, "sip:sip.example.com")
```

or `{:error, reason}` if the request could not be generated (an invalid
URI or option, an unknown dialog...). If it can not be sent (the name does
not resolve, no listener for the transport, the connection is refused),
the result is `{:error, :service_unavailable}`. A destination that does
not answer generates a `408` response.

`metas` has the values asked for with `:get_meta`: parts of the response
(`:reason_phrase`, `:contacts`, `:body`, `:call_id`, `:cseq_num`, `:to_tag`,
`:all_headers`...) or headers by name (always lowercase), as lists of
values:

```elixir
{:ok, 200, [{:reason_phrase, "OK"}, {"server", ["Asterisk"]}]} =
  Caracola.UAC.options(MyUA, uri, get_meta: [:reason_phrase, "server"])
```

Responses to INVITE from 101 to 299 have the dialog handle first (`[dialog: dialog]`),
and 2xx responses to SUBSCRIBE and REFER the subscription handle
(`[subscription: subscription]`).

### Asynchronous requests

With `:async`, the function returns at once with `{:async, handle}`, and the
responses go to the `:callback` function:

```elixir
{:async, handle} =
  Caracola.UAC.invite(MyUA, uri, [
    :async,
    callback: fn
      {:resp, code, _resp} -> send(pid, {:invite, code})
      {:error, error} -> send(pid, {:invite_error, error})
    end
  ])

# Cancels it, if there is no final response yet
Caracola.UAC.cancel(handle)
```

The callback also gets the provisional responses (`{:resp, 180, resp}`) in
synchronous mode, and the request sent (`{:req, req}`) with `:get_request`.

## Headers and body

The common headers have options: `from:`, `to:`, `route:`, `contact:`,
`content_type:`, `expires:`, `event:`, `require:`, `supported:`... Others
are added with `{:add, name, value}`, `{:replace, name, value}` or
`{:insert, name, value}`:

```elixir
Caracola.UAC.message(MyUA, "sip:bob@example.com", [
  {:add, "x-custom", "value"},
  content_type: "text/plain",
  body: "Hello"
])
```

Some options add headers: `:allow`, `:supported`, `:accept` and
`:allow_event` from the service configuration, `:date` the current date,
and `:user_agent` a `Caracola` User-Agent. `:contact`
adds a Contact with the address of the transport used (INVITE, SUBSCRIBE,
NOTIFY, REFER and UPDATE get one automatically).

The body can be a binary or a `Caracola.SDP`, which also sets the
Content-Type:

```elixir
sdp = Caracola.SDP.new("10.0.0.1", [{"audio", 4000, [{:rtpmap, 0, "PCMU/8000"}]}])
Caracola.UAC.invite(MyUA, uri, body: sdp)
```

URI headers in the destination are added to the request:
`"<sip:bob@example.com?subject=hi&priority=urgent>"`.

## Authentication

`password: password` answers the 401 and 407 challenges of the request:
it is sent again with the credentials. It can be a list of passwords, or
`{realm, password}` pairs; `{:ha1, hex}` (MD5) and `{:ha1, algorithm, hex}`
are precomputed digests (see `Caracola.Digest.ha1/4`). SHA-256 and
SHA-512-256 challenges are answered too. The `:password` of the service configuration is
also used. See [Authentication](08-authentication.md).

## Registrations

```elixir
# Registers the address of the transport used, for an hour
Caracola.UAC.register(MyUA, "sip:registrar.example.com", [:contact, expires: 3600])

# The current contacts
{:ok, 200, [contacts: contacts]} =
  Caracola.UAC.register(MyUA, "sip:registrar.example.com", get_meta: [:contacts])

# Removes our contact, or all of them
Caracola.UAC.register(MyUA, "sip:registrar.example.com", [:unregister])
Caracola.UAC.register(MyUA, "sip:registrar.example.com", [:unregister_all])
```

To keep a registration refreshed, see `Caracola.UACAutoRegister`.

## In-dialog requests

Requests inside a dialog are sent with the dialog handle instead of the
service and URI. Their From, To, Call-ID, CSeq, Route and Contact come from
the dialog:

```elixir
{:ok, 200, [dialog: dialog]} = Caracola.UAC.invite(MyUA, uri, body: sdp)
:ok = Caracola.UAC.ack(dialog)
{:ok, 200, []} = Caracola.UAC.info(dialog, body: "...", content_type: "application/x")
{:ok, 200, _} = Caracola.UAC.invite(dialog, body: new_sdp)   # re-INVITE
:ok = Caracola.UAC.ack(dialog)
{:ok, 200, []} = Caracola.UAC.bye(dialog)
```

The ACK of a 2xx response to INVITE must be sent with `Caracola.UAC.ack/2`,
unless the INVITE has the `:auto_2xx_ack` option. `Caracola.UAC.refresh/2`
sends a re-INVITE with the current local SDP (with a new version), and can
put the call on hold (`:hold`, `:inactive`, `:active`).

See [Dialogs and subscriptions](06-dialogs-and-subscriptions.md).

## Other options

* `call_id:` and `cseq_num:` - use these Call-ID and CSeq number.
* `timeout:` - maximum time to wait (milliseconds).
* `:no_dialog` - do not create dialogs with this request.
* `:new_connection` - use a new connection, instead of reusing one.
* `tls:`, `connect_timeout:`, `idle_timeout:` - options for new connections.

See `Caracola.UAC` for the full list, including the options of the plugins
(`session_expires:`, `reg_id:`, `refer_to:`...).
