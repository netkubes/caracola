# Authentication

Caracola implements digest authentication (RFC 2617), with the MD5,
SHA-256 and SHA-512-256 algorithms (RFC 7616 and RFC 8760), both to
challenge incoming requests and to answer challenges.

## As server

Every new request goes through `sip_authorize(auth_list, req, call)`. It
returns:

* `:ok` - the request is authorized.
* `:forbidden` - reply 403.
* `:authenticate` or `{:authenticate, realm}` - reply 401 with a
  WWW-Authenticate challenge.
* `:proxy_authenticate` or `{:proxy_authenticate, realm}` - reply 407 with a
  Proxy-Authenticate challenge (for proxies).

The default realm is the domain of the From header.

Challenges offer the algorithms of the `:digest_algorithms` option, one
WWW-Authenticate or Proxy-Authenticate header for each, the strongest
first. It is `[:md5]` by default, for older clients; credentials with
other algorithms are `:invalid`.

```elixir
use Malla.Service,
  plugins: [Caracola.Registrar],
  sip: [listen: "sip:all:5060", digest_algorithms: [:sha512_256, :sha256, :md5]]
```

The callback is called first with an empty list, as a fast path. If it does
not return `:ok`, it is called again with the authorization list:

* `:dialog` - the request is inside a dialog and comes from an address
  authorized in it (one that sent or received a 2xx response).
* `:register` - it comes from the address of a registered contact of the
  user of the From (with `Caracola.Registrar`).
* `{{:digest, realm}, result}` - for the credentials of each realm in the
  request: `true` if the password is right, `false` if it is wrong (or the
  user is unknown), `:invalid` if the credentials are invalid or have an
  unknown or expired nonce.

The passwords come from `sip_get_user_pass(user, realm, req, call)`, which
returns the password, a precomputed HA1 (`{:ha1, hex}` for MD5, or
`{:ha1, algorithm, hex}`, see `Caracola.Digest.ha1/4`), `true` to accept
any password or `false` if the user is unknown. An HA1 only verifies
credentials of its algorithm.

```elixir
defcb sip_get_user_pass(user, "example.com", _req, _call), do: MyUsers.password(user) || false

defcb sip_authorize(auth_list, req, _call) do
  cond do
    :dialog in auth_list or :register in auth_list -> :ok
    List.keyfind(auth_list, {:digest, "example.com"}, 0) == {{:digest, "example.com"}, true} -> :ok
    List.keymember?(auth_list, {:digest, "example.com"}, 0) -> :forbidden
    req.class == {:req, :register} -> {:authenticate, "example.com"}
    true -> {:proxy_authenticate, "example.com"}
  end
end
```

Nonces are valid for `:nonce_timeout` seconds (30 by default) and tied to
the address of the client.

## As client

A request sent with `password: password` answers 401 and 407 responses: it
is sent again with the credentials (a new CSeq, the same Call-ID), up to
`:auto_auth_max_tries` times (5 by default). The `:password` of the service
configuration is also used, after the ones in the request options.

Passwords can be:

* a binary, for any realm,
* `{:ha1, hex}` (MD5) or `{:ha1, algorithm, hex}`, a precomputed hash
  (`Caracola.Digest.ha1/4`),
* `{realm, password}`, only for that realm,
* a list of them.

```elixir
Caracola.UAC.register(MyUA, "sip:example.com", [:contact, password: "secret"])
```

When a response has several challenges for a realm (one for each
algorithm), the one with the strongest algorithm that can be answered is
used: SHA-512-256, then SHA-256, then MD5. Challenges of different realms
(as from several proxies) are all answered.

In-dialog requests are authorized too, as are re-INVITEs and BYEs
challenged by a proxy.
