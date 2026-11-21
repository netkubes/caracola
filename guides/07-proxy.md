# Proxies

A service acts as a proxy for the requests that `sip_route/5` sends to
other destinations:

* `:proxy` - to the Request-URI.
* `{:proxy, uri_set}` - to these URIs.
* `{:proxy, uri_set, opts}` - with options.
* `:proxy_stateless`, `{:proxy_stateless, uri_set}` and
  `{:proxy_stateless, uri_set, opts}` - without state.

```elixir
# Requests to the domain itself, like REGISTER, are processed here
defcb sip_route(_scheme, nil, "example.com", _req, _call), do: :process

defcb sip_route(scheme, user, "example.com", _req, call) do
  case Caracola.Registrar.qfind(call.service, scheme, user, "example.com") do
    [] -> {:reply, :temporarily_unavailable}
    uri_set -> {:proxy, uri_set, [:record_route]}
  end
end

defcb sip_route(_scheme, _user, _domain, _req, _call), do: :proxy
```

In-dialog requests (with To tag) arriving at a proxy that recorded the
route go through `sip_route/5` too; proxying them to `:ruri` is usually
right.

## Routing later

`sip_route/5` can return `:noreply` to decide the route in another
process, for example after querying a database or waking up a device, and
then call `Caracola.route/2` with the result. The INVITE has already been
answered with a 100, and the request can be cancelled or time out
meanwhile (then `Caracola.route/2` returns an error).

```elixir
defcb sip_route(_scheme, user, _domain, req, _call) do
  Task.start(fn -> Caracola.route(req, {:proxy, MyApp.lookup(user)}) end)
  :noreply
end
```

## URI sets

A URI set is:

* `:ruri` - the Request-URI of the request,
* a URI (string or `Caracola.URI`), or a string with several of them
  separated by commas,
* a list of URIs: the destinations are tried in parallel (forking),
* a list of lists: groups tried in order (serial forking), each group in
  parallel. The next group is tried if all the destinations of the current
  one fail.

`Caracola.Registrar.qfind/4` returns the registered contacts of a user as
groups by `q` value, the highest first.

## Stateful proxies

A stateful proxy keeps a transaction per destination, and:

* Sends provisional responses back at once, and the first 2xx (and any
  other 2xx, for INVITE).
* Cancels the pending branches after a 2xx or 6xx response, or when the
  request is cancelled.
* Answers with the best response when all the branches finish (RFC 3261
  §16.7): 6xx first, then the lowest class, with all the challenges of 401
  and 407 responses; 503 becomes 500.
* With `:follow_redirects`, tries the Contacts of 3xx responses.

## Stateless proxies

A stateless proxy forwards the request and forgets it. Responses are sent
back using the Via headers. It has less overhead, but can not fork (only
the first URI is used) nor follow redirects. Retransmissions follow the
same path.

## Options

Proxy options are the header options of `Caracola.UAC` (`{:add, name,
value}`, `{:replace, name, value}`, `route:`...), applied to the request,
plus:

* `:record_route` - add a Record-Route, so that the in-dialog requests go
  through the proxy.
* `:path` - add a Path to REGISTER requests (RFC 3327), so that requests to
  the registered contact go through the proxy.
* `:follow_redirects` - follow 3xx responses.

## Checks

Before proxying, Caracola checks Max-Forwards (483, or a 200 for OPTIONS
with Max-Forwards 0), Proxy-Require (420: proxies support no extensions)
and, for REGISTER with `:path`, that the client supports Path (421). It
decrements Max-Forwards and removes the routes pointing to the proxy.

Requests whose Request-URI has URI headers (as the contacts of a registrar
with Path) get those headers.

## Redirect servers

A redirect server answers with the destinations instead of proxying:

```elixir
defcb sip_route(scheme, user, domain, _req, call) do
  case Caracola.Registrar.find(call.service, scheme, user, domain) do
    [] -> {:reply, :not_found}
    contacts -> {:reply, {:redirect_temporary, contacts}}
  end
end
```

## Call history

When a proxy forwards a call to another target (call forwarding, a
voicemail), `Caracola.History.retarget/3` proxies it adding a
`History-Info` entry (RFC 7044) for each target, with the `cause` of the
retargeting (RFC 4458), and optionally a `Diversion` header (RFC 5806):

```elixir
defcb sip_route(_scheme, "alice", _domain, req, _call),
  do: Caracola.History.retarget(req, ["sip:vm@example.com"], [:diversion, cause: 486])
```

The final destination reads them with `Caracola.History.entries/1` and
`Caracola.History.diversions/1`.

## Outbound

With `Caracola.Outbound`, edge proxies keep the flows of the clients
(RFC 5626): requests for them go through the connection they registered
from, even behind NAT.
