defmodule Caracola.Tutorial.Server do
  @moduledoc """
  Server of the [tutorial](03-tutorial.md): a registrar and a stateful proxy
  for the `example.com` domain, that requires digest authentication.

  It listens on all interfaces, port 5060 for UDP and TCP and 5061 for TLS.
  """

  use Malla.Service,
    plugins: [Caracola.Registrar],
    sip: [
      listen: "sip:all:5060, <sip:all:5061;transport=tls>",
      # Its Record-Route will point to 127.0.0.1, the address the clients
      # use, so that in-dialog requests reuse their connections
      local_host: "127.0.0.1"
    ]

  alias Caracola.{Registrar, Transport}

  # The password for any user is "1234" in the "example.com" realm. Other realms
  # have no valid passwords.
  defcb sip_get_user_pass(_user, "example.com", _req, _call), do: "1234"
  defcb sip_get_user_pass(_user, _realm, _req, _call), do: false

  # A request is authorized if it comes from an authorized origin of its
  # dialog, or from a registered contact, or it has valid credentials for
  # the "example.com" realm. Wrong credentials get a 403, and requests without
  # them a 407 with a challenge.
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

  # Requests for the "example.com" domain without user are processed here.
  # Requests for its users are proxied to their registered contacts,
  # staying in the path of the dialogs (Record-Route). Other requests are
  # processed if they are for us, or proxied to their Request-URI.
  defcb sip_route(_scheme, nil, "example.com", _req, _call), do: :process

  defcb sip_route(scheme, user, "example.com", _req, call) do
    case Registrar.qfind(call.service, scheme, user, "example.com") do
      [] -> {:reply, :temporarily_unavailable}
      uri_set -> {:proxy, uri_set, [:record_route]}
    end
  end

  defcb sip_route(_scheme, _user, _domain, req, call) do
    if Transport.local?(call.service, req.ruri, call.config),
      do: :process,
      else: :proxy
  end
end
