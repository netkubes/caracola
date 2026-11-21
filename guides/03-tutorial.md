# Tutorial

This tutorial covers the basic aspects of Caracola. It is a port of the
NkSIP tutorial: we start a server, acting as registrar and proxy with
authentication, and two clients, and send some requests between them.

The code is in the `examples/tutorial` directory of the project, and it is
compiled in the `dev` and `test` environments. `Caracola.Tutorial.launch/0`
runs all the steps of this tutorial (and it is part of the test suite).

From a checkout of Caracola:

```bash
mix deps.get
iex -S mix
```

## The services

The server is `Caracola.Tutorial.Server`. It uses the
`Caracola.Registrar` plugin, to process registrations, and listens on all
the interfaces, port 5060 for UDP and TCP and 5061 for TLS:

```elixir
defmodule Caracola.Tutorial.Server do
  use Malla.Service,
    plugins: [Caracola.Registrar],
    sip: [
      listen: "sip:all:5060, <sip:all:5061;transport=tls>",
      local_host: "127.0.0.1"
    ]

  alias Caracola.{Registrar, Transport}

  # ... callbacks, see below
end
```

As it listens on all interfaces, the host in its headers (like
Record-Route) would be the main IP of the machine. With `:local_host` it
is `127.0.0.1`, the address the clients use, so that the requests inside
the dialogs reuse their connections (and are authorized, as we will see).

The clients are `Caracola.Tutorial.Client1`, listening on `127.0.0.1`,
port 5070 for UDP and TCP and 5071 for TLS, and
`Caracola.Tutorial.Client2`, listening on all interfaces, random ports.
Each one has its own From; the second one uses `sips`:

```elixir
defmodule Caracola.Tutorial.Client1 do
  use Malla.Service,
    plugins: [Caracola],
    sip: [
      listen: "sip:127.0.0.1:5070, <sip:127.0.0.1:5071;transport=tls>",
      from: "sip:client1@example.com"
    ]

  use Caracola.Tutorial.Client
end

defmodule Caracola.Tutorial.Client2 do
  use Malla.Service,
    plugins: [Caracola],
    sip: [
      listen: "sip:all:0, <sip:all:0;transport=tls>",
      from: "sips:client2@example.com"
    ]

  use Caracola.Tutorial.Client
end
```

TLS listeners need a certificate. `Caracola.Tutorial.tls_config/0`
generates one for the tutorial, with a certificate authority that the
clients trust (`:tls_client`). `Caracola.Tutorial.start/0` starts the three
services with it:

```elixir
iex> Caracola.Tutorial.start()
:ok
```

which is basically:

```elixir
{server_tls, client_tls} = Caracola.Tutorial.tls_config()
tls = [tls: server_tls, tls_client: client_tls]
Caracola.Tutorial.Server.start_link(sip: tls)
Caracola.Tutorial.Client1.start_link(sip: tls)
Caracola.Tutorial.Client2.start_link(sip: tls)
```

From now on, you can see all the SIP messages in the console with:

```elixir
iex> Caracola.Telemetry.trace(true)
:ok
```

Let's alias the modules we will use:

```elixir
iex> alias Caracola.{Dialog, SDP, UAC}
iex> alias Caracola.Tutorial.{Client1, Client2, Server}
```

## Authentication

Let's send an OPTIONS from client2 to client1, and from client1 to the
server:

```elixir
iex> UAC.options(Client2, "sip:127.0.0.1:5070")
{:ok, 200, []}
iex> UAC.options(Client1, "sip:127.0.0.1", get_meta: [:reason_phrase])
{:ok, 407, [reason_phrase: "Proxy Authentication Required"]}
```

The server did not accept the request (we used the `:get_meta` option to
get the reason phrase of the response).

The clients do not implement any authentication callback, so they accept
every request. The server is different:

```elixir
# The password for any user is "1234" in the "example.com" realm. Other realms
# have no valid passwords.
defcb sip_get_user_pass(_user, "example.com", _req, _call), do: "1234"
defcb sip_get_user_pass(_user, _realm, _req, _call), do: false

defcb sip_authorize(auth_list, _req, _call) do
  cond do
    :dialog in auth_list or :register in auth_list ->
      :ok

    true ->
      case List.keyfind(auth_list, {:digest, "example.com"}, 0) do
        {_, true} -> :ok
        {_, _} -> :forbidden
        nil -> {:proxy_authenticate, "example.com"}
      end
  end
end
```

`sip_authorize/3` gets a list with the information Caracola has about the
request:

1. `:dialog` if it is an in-dialog request coming from the same address as
   an authorized request of that dialog.
2. `:register` if it comes from the address of a registered contact (the
   registrar plugin adds it).
3. `{{:digest, "example.com"}, true}` if it has valid credentials for the realm
   `"example.com"`, or `false` if the password was wrong.

If none is present, we reply with a 407 and a challenge for the realm
`"example.com"`.

We try again with the password. In the second request we ask for TLS. Note
we must use `<` and `>` when the URI has parameters, like `transport`:

```elixir
iex> UAC.options(Client1, "sip:127.0.0.1", password: "1234")
{:ok, 200, []}
iex> UAC.options(Client2, "<sip:127.0.0.1;transport=tls>", password: "1234")
{:ok, 200, []}
```

Both requests get a 407 first, but Caracola uses the password to send them
again with the credentials, and the server accepts them.

## Registration

Let's register the clients at the server. The `:contact` option adds a
Contact header with the address of the client, and we ask for the Contact
of the response, to check that the server stored it:

```elixir
iex> UAC.register(Client1, "sip:127.0.0.1", [:contact, password: "1234", get_meta: ["contact"]])
{:ok, 200, [{"contact", ["<sip:client1@127.0.0.1:5070>;expires=3600"]}]}
iex> UAC.register(Client2, "sips:127.0.0.1", [:contact, password: "1234"])
{:ok, 200, []}
```

A REGISTER without Contact gets the stored contacts. This time we get them
parsed, as `Caracola.URI` structs (`:all_headers` would return the headers
that are not parsed into fields of `Caracola.Message`):

```elixir
iex> UAC.register(Client2, "sips:127.0.0.1", password: "1234", get_meta: [:contacts])
{:ok, 200, [contacts: [%Caracola.URI{scheme: :sips, user: "client2", ...}]]}
```

Now, requests from the registered addresses do not need the password,
thanks to the `:register` value in the authorization list:

```elixir
iex> UAC.options(Client1, "sip:127.0.0.1")
{:ok, 200, []}
iex> UAC.options(Client2, "sips:127.0.0.1")
{:ok, 200, []}
```

## Proxying

The server routes the requests with `sip_route/5`:

```elixir
# Requests for the "example.com" domain without user are processed here
defcb sip_route(_scheme, nil, "example.com", _req, _call), do: :process

# Requests for its users are proxied to their registered contacts,
# staying in the path of the dialogs (Record-Route)
defcb sip_route(scheme, user, "example.com", _req, call) do
  case Registrar.qfind(call.service, scheme, user, "example.com") do
    [] -> {:reply, :temporarily_unavailable}
    uri_set -> {:proxy, uri_set, [:record_route]}
  end
end

# Other requests are processed if they are for us, or proxied
defcb sip_route(_scheme, _user, _domain, req, call) do
  if Transport.local?(call.service, req.ruri, call.config),
    do: :process,
    else: :proxy
end
```

Let's send an OPTIONS from client1 to client2 through the proxy, using its
address-of-record. The `:route` option sends the request to the proxy (the
`:route` of the service configuration would send all the requests there).

The first one is not authorized: the target is a `sips` URI, so the request
goes over TLS, and the origin is not the registered one (client1 registered
over UDP):

```elixir
iex> UAC.options(Client1, "sips:client2@example.com", route: "<sip:127.0.0.1;lr>")
{:ok, 407, []}
iex> UAC.options(Client1, "sips:client2@example.com",
...>   route: "<sip:127.0.0.1;lr>", password: "1234", get_meta: ["x-caracola-id"])
{:ok, 200, [{"x-caracola-id", ["client2"]}]}
```

We asked for the X-Caracola-Id header of the response (header names are always
lowercase). The clients add it in their `sip_options/2` callback:

```elixir
defcb sip_options(_req, call) do
  name = call.service |> Module.split() |> List.last() |> String.downcase()
  {:reply, {:ok, [{:add, "x-caracola-id", name}, :contact, :allow, :accept, :supported]}}
end
```

## A call

Now an INVITE from client2 to client1, through the proxy. Client1 gets it in
its `sip_invite/2` callback:

```elixir
defcb sip_invite(req, _call) do
  case SDP.from_message(req) do
    %SDP{} = sdp ->
      spawn(fn ->
        :ok = Caracola.reply(req, :ringing)
        Process.sleep(2000)
        Caracola.reply(req, {:answer, sdp})
      end)

      :noreply

    nil ->
      {:reply, {:not_acceptable, "Invalid SDP"}}
  end
end
```

Without a SDP body, the request is rejected with a 488. With it, the
callback starts a process that replies a 180 Ringing, waits two seconds and
replies a 200 with the same SDP, and returns `:noreply`. Callbacks run in
the process of the call, so they must not block: slow work goes to other
processes, which reply with `Caracola.reply/2`.

```elixir
iex> UAC.invite(Client2, "sip:client1@example.com", route: "<sips:127.0.0.1;lr>")
{:ok, 488, []}
iex> sdp = SDP.new("127.0.0.1", [{"audio", 1080, [{:rtpmap, 0, "PCMU/8000"}]}])
iex> {:ok, 200, [dialog: dialog]} =
...>   UAC.invite(Client2, "sip:client1@example.com",
...>     [:auto_2xx_ack, route: "<sips:127.0.0.1;lr>", body: sdp])
```

Responses to INVITE always return the handle of their dialog. A 2xx
response must be acknowledged with an ACK; the `:auto_2xx_ack` option sends
it automatically, instead of calling `Caracola.UAC.ack/2` with the dialog.

The call is accepted, and the dialog is confirmed:

```elixir
iex> {:ok, %Dialog{invite: %{status: status}}} = Dialog.get(dialog)
iex> status
:confirmed
```

The dialog lives in both clients, with the proxy in its route set (the
proxy does not keep dialogs, it only stays in their path):

```elixir
iex> {:dialog, _, call_id, _} = dialog
iex> Dialog.list(Client1, call_id)
[{:dialog, Caracola.Tutorial.Client1, "...", "..."}]
```

Let's hang up and stop the services:

```elixir
iex> UAC.bye(dialog)
{:ok, 200, []}
iex> Caracola.Tutorial.stop()
:ok
```

The BYE goes through the proxy, from the same TLS connection used to
register client2, so the server authorizes it without password.

## What next

* [A small PBX](15-small-pbx.md) is a second tutorial, with a B2BUA,
  busy lamps and call forwarding.
* [Sending requests](04-sending-requests.md) and
  [Receiving requests](05-receiving-requests.md) describe the options and
  callbacks used here.
* [Proxies](07-proxy.md) covers routing, forking and redirects.
* [Plugins](10-plugins.md) lists the SIP extensions.
