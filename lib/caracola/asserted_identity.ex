defmodule Caracola.AssertedIdentity do
  @moduledoc """
  Asserted identity within a trust domain (RFC 3325) and privacy (RFC
  3323): the `P-Asserted-Identity`, `P-Preferred-Identity` and `Privacy`
  headers.

  ```
  defmodule MyProxy do
    use Malla.Service,
      plugins: [Caracola.AssertedIdentity],
      sip: [listen: "sip:all:5060"],
      asserted_identity: [trusted: ["10.0.0.0/8", "192.0.2.10"]]
  end
  ```

  The trust domain is the list of `:trusted` addresses (IPv4 or IPv6, with
  an optional prefix length). P-Asserted-Identity headers of requests
  received from any other address are removed before they are authorized
  or routed (RFC 3325 §5), so `identities/1` only returns identities
  asserted by trusted nodes.

  A proxy that has authenticated a user asserts its identity with the
  options of `assert_opts/1` (which also remove P-Preferred-Identity), and
  before forwarding a request outside the trust domain uses the options of
  `forward_opts/2`, which remove the asserted identity if the user asked
  for it with `Privacy: id` (RFC 3325 §9.3):

  ```
  defcb sip_route(_scheme, user, "example.com", req, call) do
    opts = Caracola.AssertedIdentity.assert_opts("<sip:" <> user <> "@example.com>")
    {:proxy, :ruri, opts ++ [:record_route]}
  end
  ```

  User agents ask for privacy with the `Privacy` header (`{:add,
  "privacy", "id"}`) and an anonymous From (RFC 3323 §4.1.1).

  ## Configuration

  Under the `:asserted_identity` key:

    * `:trusted` - addresses of the trust domain (default `[]`).
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.{Message, URI, Util}

  @schema NimbleOptions.new!(
            trusted: [
              type: {:list, :string},
              default: [],
              doc: "Addresses of the trust domain, as `10.0.0.0/8` or `192.0.2.1`."
            ]
          )

  @typedoc "A privacy value of the `Privacy` header (RFC 3323, RFC 3325)."
  @type privacy :: :id | :header | :session | :user | :none | :critical | String.t()

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  The identities asserted in a request (P-Asserted-Identity), only present
  if it came from the trust domain.
  """
  @spec identities(Message.t()) :: [URI.t()]
  def identities(%Message{} = msg), do: uris(msg, "p-asserted-identity")

  @doc "The identities a user agent asks to be asserted (P-Preferred-Identity)."
  @spec preferred(Message.t()) :: [URI.t()]
  def preferred(%Message{} = msg), do: uris(msg, "p-preferred-identity")

  @doc """
  The privacy values of a message (RFC 3323 §4.2).

      iex> {:ok, msg} = Caracola.Message.update_header(%Caracola.Message{}, :add, "Privacy", "id; critical")
      iex> Caracola.AssertedIdentity.privacy(msg)
      [:id, :critical]
  """
  @spec privacy(Message.t()) :: [privacy()]
  def privacy(%Message{} = msg) do
    for value <- Message.header(msg, "privacy"),
        token <- String.split(value, [";", ","], trim: true),
        token = token |> String.trim() |> Util.ascii_downcase(),
        token != "",
        do: privacy_value(token)
  end

  defp privacy_value("id"), do: :id
  defp privacy_value("header"), do: :header
  defp privacy_value("session"), do: :session
  defp privacy_value("user"), do: :user
  defp privacy_value("none"), do: :none
  defp privacy_value("critical"), do: :critical
  defp privacy_value(other), do: other

  @doc """
  Proxy or request options asserting identities (a URI or a list of
  them, as a SIP URI and a tel URI): they replace P-Asserted-Identity and
  remove P-Preferred-Identity.
  """
  @spec assert_opts(String.t() | URI.t() | [String.t() | URI.t()]) :: list()
  def assert_opts(identities) do
    [
      {:replace, "p-asserted-identity", List.wrap(identities)},
      {:remove, "p-preferred-identity"}
    ]
  end

  @doc """
  Proxy options to forward a request: if the destination is not trusted
  and the request has `Privacy: id`, the asserted identity is removed.
  """
  @spec forward_opts(Message.t(), boolean()) :: list()
  def forward_opts(%Message{} = req, trusted_destination?) do
    if not trusted_destination? and :id in privacy(req),
      do: [{:remove, "p-asserted-identity"}],
      else: []
  end

  @doc "Returns `true` if an address belongs to the trust domain of a service."
  @spec trusted?(module(), :inet.ip_address()) :: boolean()
  def trusted?(service, ip) when is_tuple(ip) do
    service
    |> config()
    |> Keyword.get(:trusted, [])
    |> then(&Util.in_networks?(ip, &1))
  end

  def trusted?(_service, _ip), do: false

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <-
           NimbleOptions.validate(Keyword.get(config, :asserted_identity, []), @schema),
         {:ok, networks} <- trusted(opts[:trusted]) do
      {:ok, Keyword.put(config, :asserted_identity, Keyword.put(opts, :trusted, networks))}
    end
  end

  # Identities asserted by untrusted nodes are removed
  defcb caracola_received_request(%Message{port: %{remote_ip: ip}} = req, call) do
    if Message.header(req, "p-asserted-identity") != [] and not trusted?(call.service, ip),
      do: {:cont, [Message.remove_header(req, "p-asserted-identity"), call]},
      else: :cont
  end

  defcb caracola_received_request(_req, _call), do: :cont

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp config(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> Keyword.get(config, :asserted_identity, [])
      _ -> []
    end
  end

  defp uris(msg, name) do
    for value <- Message.header(msg, name),
        {:ok, uris} <- [URI.parse(value)],
        uri <- uris,
        do: uri
  end

  defp trusted(list) do
    case Util.parse_networks(list) do
      {:ok, networks} -> {:ok, networks}
      {:error, {:invalid_network, value}} -> {:error, {:invalid_trusted_address, value}}
    end
  end
end
