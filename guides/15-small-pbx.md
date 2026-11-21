# Tutorial: a small PBX

The [first tutorial](03-tutorial.md) covers the basics: requests, digest
authentication, registrations and a proxy. This one builds something closer
to a real application, a small office PBX, with three plugins:

* a **registrar** where the phones register,
* a **B2BUA** that connects the calls between extensions, and
* a **dialog state server** that lights the busy lamps of the phones.

It also forwards the calls of an absent user to a voicemail, telling the
voicemail who the call was for with the `History-Info` and `Diversion`
headers.

The code is in `examples/tutorial/office.ex`, compiled in the `dev` and
`test` environments. `Caracola.Tutorial.Office.launch/0` runs all the steps
of this tutorial, and it is part of the test suite. From a checkout:

```bash
iex -S mix
```

```elixir
iex> alias Caracola.{DialogInfo, History, UAC}
iex> alias Caracola.Tutorial.Office
iex> Office.start()
:ok
```

## The services

There are four services, all listening on `127.0.0.1`:

| Service | Address | Role |
|---|---|---|
| `Office.PBX` | port 5080 | Registrar, B2BUA, dialog state |
| `Office.Alice` | random port | Phone of `alice@example.com` |
| `Office.Bob` | random port | Phone of `bob@example.com` |
| `Office.Voicemail` | random port | `voicemail@example.com` |

The phones are plain user agents. They answer at once any INVITE that has
SDP, with the same SDP they received, and send the NOTIFYs they get to the process that
started the services, so we can see them in the shell.

The PBX lists the three plugins:

```elixir
defmodule Caracola.Tutorial.Office.PBX do
  use Malla.Service,
    plugins: [Caracola.Registrar, Caracola.B2BUA, Caracola.DialogInfo],
    sip: [listen: "sip:127.0.0.1:5080"],
    # Carol is out
    forward: %{"carol" => "voicemail"}

  alias Caracola.{B2BUA, History, Registrar, Transport}

  # ... callbacks, see below
end
```

Extra keys like `:forward` are kept in the configuration of the service,
and read with `call.service.get_config()`. Carol has no phone: all her
calls go to the voicemail.

## Registering the phones

The PBX authenticates with digest, as in the first tutorial: every user has
the password `1234` in the `example.com` realm, and requests from the address
of a registered contact need no password.

```elixir
iex> pbx = "sip:127.0.0.1:5080"
iex> for phone <- [Office.Alice, Office.Bob, Office.Voicemail] do
...>   UAC.register(phone, pbx, [:contact, password: "1234"])
...> end
[{:ok, 200, []}, {:ok, 200, []}, {:ok, 200, []}]
```

The phones use `from: "sip:alice@example.com"` and so on, so each one
registers the address of record of its extension. From now on, all the requests
from the phones can go through the PBX with `route: "<sip:127.0.0.1:5080;lr>"`
and no password.

## A call between extensions

The PBX routes the requests for `example.com` in `sip_route/5`. Calls to a
user with no forwarding are processed by the PBX itself, and arrive at
`sip_invite/2`, where the call is bridged to the first registered contact of
the extension:

```elixir
defcb sip_invite(req, call) do
  case Registrar.find(call.service, req.ruri.scheme, req.ruri.user, "example.com") do
    [] -> {:reply, :temporarily_unavailable}
    [contact | _] -> B2BUA.bridge(req, contact)
  end
end
```

`Caracola.B2BUA.bridge/3` answers nothing by itself: it starts a process
that sends a new INVITE to the contact, relays the responses to the
caller, and keeps both dialogs together afterwards, relaying hangups and
re-INVITEs. The two legs are separate dialogs, with their own Call-ID and
tags: Bob never sees the address of Alice, only the PBX
(see [Plugins](10-plugins.md#b2bua)).

Let's call Bob from Alice:

```elixir
iex> route = "<sip:127.0.0.1:5080;lr>"
iex> sdp = Caracola.SDP.new("127.0.0.1", [{"audio", 1080, [{:rtpmap, 0, "PCMU/8000"}]}])
iex> {:ok, 200, [dialog: dialog]} =
...>   UAC.invite(Office.Alice, "sip:bob@example.com", [:auto_2xx_ack, route: route, body: sdp])
```

The `:auto_2xx_ack` option sends the ACK for us. Bob's phone has sent a
message `{:invite, Caracola.Tutorial.Office.Bob, req}` to the shell:

```elixir
iex> flush()
{:invite, Caracola.Tutorial.Office.Bob, %Caracola.Message{...}}
```

## Busy lamps

A phone shows the state of the line of a colleague subscribing to its
`dialog` event (RFC 4235). `Caracola.DialogInfo` answers these SUBSCRIBEs for
the extensions of the PBX, and it follows the INVITE dialogs of the service
whose local URI has the address of the extension. In our PBX, the A leg of
a call to Bob is a dialog with `bob@example.com` as local URI, so the PBX
notifies it with no extra code.

Let's hang up the call, and subscribe Alice to the line of Bob before
calling again:

```elixir
iex> UAC.bye(dialog)
{:ok, 200, []}
iex> UAC.subscribe(Office.Alice, "sip:bob@example.com", event: "dialog", route: route)
{:ok, 200, [subscription: {:subscription, Caracola.Tutorial.Office.Alice, "...", "...", "..."}]}
iex> body = receive do {:notify, body} -> body end
"<?xml version=\"1.0\"..."
```

The NOTIFY has the full state of the line. `Caracola.DialogInfo.decode/1`
parses it:

```elixir
iex> {:ok, doc} = DialogInfo.decode(body)
iex> doc.dialogs
[]
```

Now Alice calls Bob again, and the lamp goes to `confirmed` (the phones
answer at once, so there is no `early` state), in new NOTIFYs with a
growing `version`: the second one adds the targets of the dialog. When the
call ends, one more NOTIFY tells that the dialog is `terminated`:

```elixir
iex> {:ok, 200, [dialog: dialog]} =
...>   UAC.invite(Office.Alice, "sip:bob@example.com", [:auto_2xx_ack, route: route, body: sdp])
iex> flush()
{:invite, Caracola.Tutorial.Office.Bob, %Caracola.Message{...}}
{:notify, "..."}   # state "confirmed"
{:notify, "..."}   # state "confirmed", with the targets
iex> UAC.bye(dialog)
iex> flush()
{:notify, "..."}   # state "terminated"
```

## Forwarding to the voicemail

Carol is out. The PBX forwards her calls to the voicemail when
`sip_route/5` sees an INVITE for her, and tells the voicemail what happened
with `Caracola.History.retarget/3`:

```elixir
defcb sip_route(scheme, user, "example.com", req, call) do
  forward = call.service.get_config()[:forward]

  with {:req, :invite} <- req.class,
       ext when is_binary(ext) <- forward[user],
       [_ | _] = contacts <- Registrar.find(call.service, scheme, ext, "example.com") do
    History.retarget(req, contacts, [:diversion, cause: 302])
  else
    _ -> :process
  end
end
```

`retarget/3` returns `{:proxy, targets, opts}`, a valid result of
`sip_route/5`: this time the PBX is not a B2BUA but a proxy, as the voicemail
does not need to be hidden from the caller. The `cause: 302` says the call
was forwarded unconditionally (RFC 4458), and `:diversion` adds a
`Diversion` header too, for equipment that only understands that one.

Let's call Carol:

```elixir
iex> {:ok, 200, [dialog: dialog]} =
...>   UAC.invite(Office.Alice, "sip:carol@example.com", [:auto_2xx_ack, route: route, body: sdp])
```

The voicemail has received the INVITE. `Caracola.History.entries/1` and
`Caracola.History.diversions/1` read what the PBX added:

```elixir
iex> req = receive do {:invite, Office.Voicemail, req} -> req end
iex> History.entries(req)
[
  %{index: "1", uri: %Caracola.URI{user: "carol", ...}, cause: nil, ...},
  %{index: "1.1", uri: %Caracola.URI{user: "voicemail", ...}, cause: 302, ...}
]
```

The first entry is the original target of the call, and the second the
one it was retargeted to. A voicemail would use the first one to choose the
mailbox:

```elixir
iex> History.diversions(req)
[%{uri: %Caracola.URI{user: "carol", ...}, reason: "unconditional", counter: 1}]
```

Finally, let's hang up and stop everything:

```elixir
iex> UAC.bye(dialog)
{:ok, 200, []}
iex> Office.stop()
:ok
```

## What next

* To see the messages the PBX exchanges, enable the telemetry events of
  [Observability](11-observability.md) or capture them with
  `Caracola.HEP`.
* Add [rate limiting and overload control](10-plugins.md#rate-limiting) to
  the PBX, and [push notifications](10-plugins.md#push-notifications) to
  wake up mobile phones.
* [Interoperability](14-interoperability-and-performance.md) shows the same
  scenarios with real phones (baresip) and servers (FreeSWITCH, Asterisk).
