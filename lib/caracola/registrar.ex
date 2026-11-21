defmodule Caracola.Registrar do
  @moduledoc """
  Registrar plugin (RFC 3261 §10, RFC 3327 Path). Equivalent to NkSIP's
  `nksip_registrar`.

  ```
  defmodule MyRegistrar do
    use Malla.Service,
      plugins: [Caracola.Registrar],
      sip: [listen: "sip:all:5060"],
      registrar: [min_time: 60]
  end
  ```

  It answers REGISTER requests (`sip_register/2`, see `request/1`), adds
  `REGISTER` to the Allow header, and adds `:register` to the authorization
  list of `sip_authorize/3` for requests coming from a registered contact
  (see `registered?/1`). Registered contacts are found with `find/4` and
  `qfind/4`, to proxy requests to them.

  ## Configuration

  Under the `:registrar` key:

    * `:min_time` - minimum expiration (secs, default 60); shorter ones
      are rejected with 423.
    * `:max_time` - maximum expiration (secs, default 86400).
    * `:default_time` - expiration without Expires (secs, default 3600).
    * `:service_route` - routes (a URI string, or a list of them) returned
      in the Service-Route header of the 2xx responses (RFC 3608): the
      registered UAs use them as the initial route set of the requests
      they send (see `Caracola.UACAutoRegister.service_route/2`).

  ## Storage

  Contacts are stored in memory. Services can use their own storage
  implementing `sip_registrar_store(op, service)`, where `op` is
  `{:get, aor}` (returns the list of `Caracola.Registrar.Contact`),
  `{:put, aor, contacts, ttl}`, `{:del, aor}` (`:ok` or `:not_found`) or
  `:del_all`.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.Call.Outbound
  alias Caracola.Gruu
  alias Caracola.{Message, URI, Util}
  alias Caracola.Registrar.{Contact, Store}

  @typedoc "An address of record: scheme, user and domain."
  @type aor :: {:sip | :sips | :tel, String.t() | nil, String.t()}

  @schema NimbleOptions.new!(
            min_time: [type: :pos_integer, default: 60, doc: "Minimum expiration (secs)."],
            max_time: [
              type: {:custom, Caracola.Config, :validate_min, [60]},
              default: 86_400,
              doc: "Maximum expiration (secs)."
            ],
            default_time: [
              type: {:custom, Caracola.Config, :validate_min, [5]},
              default: 3600,
              doc: "Default expiration (secs)."
            ],
            service_route: [
              type: {:or, [:string, {:list, :string}]},
              default: [],
              doc: "Service-Route of the 2xx responses."
            ]
          )

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc "Returns the registered contacts of an AOR (or of the AOR of a URI)."
  @spec find(module(), aor() | URI.t()) :: [URI.t()]
  def find(service, %URI{scheme: scheme, user: user, domain: domain}),
    do: find(service, scheme, user, domain)

  def find(service, {scheme, user, domain}), do: find(service, scheme, user, domain)

  @doc "Returns the registered contacts of an AOR."
  @spec find(module(), atom(), String.t() | nil, String.t()) :: [URI.t()]
  def find(service, scheme, user, domain),
    do: for(reg <- get_info(service, {scheme, user, domain}), do: make_contact(reg))

  @doc """
  Returns the registered contacts of an AOR as a URI set for proxying
  (see [Proxies](07-proxy.md)): groups with the same `q`, the
  highest first, tried in order; in each group, the last registered first.
  """
  @spec qfind(module(), atom(), String.t() | nil, String.t()) :: [[URI.t()]]
  def qfind(service, scheme, user, domain) do
    get_info(service, {scheme, user, domain})
    |> Enum.sort_by(&{-&1.q, -&1.updated})
    |> Enum.chunk_by(& &1.q)
    |> Enum.map(fn regs -> Enum.map(regs, &make_contact/1) end)
  end

  @doc "Returns the registration records of an AOR."
  @spec get_info(module(), aor()) :: [Contact.t()]
  def get_info(service, aor) do
    now = System.os_time(:second)
    for %Contact{expire: expire} = reg <- store(service, {:get, aor}), expire > now, do: reg
  end

  @doc "Deletes the registrations of an AOR."
  @spec delete(module(), atom(), String.t() | nil, String.t()) :: :ok | :not_found
  def delete(service, scheme, user, domain), do: store(service, {:del, {scheme, user, domain}})

  @doc "Deletes all the registrations of a service."
  @spec clear(module()) :: :ok
  def clear(service), do: store(service, :del_all)

  @doc """
  Returns `true` if a request comes from a registered contact of the AOR
  of its From: from the same transport, IP and port as the REGISTER, or the
  address of a registered Contact.
  """
  @spec registered?(Message.t()) :: boolean()
  def registered?(%Message{class: {:req, :register}}), do: false

  def registered?(%Message{from: from, port: %{} = port} = req) do
    origin = {port.transport, port.remote_ip, port.remote_port}

    req.service
    |> get_info(aor(from))
    |> Enum.any?(&(&1.origin == origin or contact_origin(&1.contact) == origin))
  end

  def registered?(%Message{}), do: false

  @doc """
  Processes a REGISTER request, returning the reply: 200 with the current
  contacts, or an error (unsupported scheme, invalid request, 423 if the
  expiration is too short, 400 for old CSeqs).

  A Contact with `expires=0` (or an Expires header with 0) removes it, and
  `*` with Expires 0 removes all the contacts of the AOR. A contact replaces
  a previous one with the same scheme, transport, user, host and port, or
  with the same `pn-provider` and `pn-prid` (RFC 8599, see
  `Caracola.Push`).
  """
  @spec request(Message.t()) :: Caracola.Reply.sipreply()
  def request(%Message{service: service, to: to} = req) do
    config = config(service)

    if to.scheme in [:sip, :sips] do
      {outbound, req} = outbound(req)
      gruu = Gruu.enabled?(Caracola.Call.config(service)) and "gruu" in req.supported
      process(req, Keyword.merge(config, outbound: outbound, gruu: gruu))
      regs = get_info(service, aor(to))

      # The registrations use outbound (RFC 5626 §6)
      require =
        if outbound == true and Enum.any?(regs, &match?({:ob, _, _}, &1.index)),
          do: [require: "outbound"],
          else: []

      service_route = for route <- config[:service_route], do: {:add, "service-route", route}

      {:ok,
       [:date, :allow, :supported, contact: Enum.map(regs, & &1.contact)] ++
         require ++ service_route}
    else
      :unsupported_uri_scheme
    end
  catch
    {:reply, reply} -> reply
  end

  # Outbound support: :none, or if the first hop supports it
  defp outbound(%Message{service: service} = req) do
    sip = Caracola.Call.config(service)

    if Outbound.enabled?(sip) do
      case Outbound.check_reg_ids(req.contacts) do
        :ok -> Outbound.registrar(req, sip)
        {:error, reason} -> throw({:reply, {:invalid_request, reason}})
      end
    else
      {:none, req}
    end
  end

  ## ===================================================================
  ## Processing
  ## ===================================================================

  defp process(%Message{contacts: contacts} = req, config) do
    default = if is_integer(req.expires), do: req.expires, else: config[:default_time]

    case contacts do
      [] -> :ok
      [%URI{domain: "*"}] when default == 0 -> del_all(req)
      _ -> update(req, contacts, default, config)
    end
  end

  defp update(%Message{service: service} = req, contacts, default, config) do
    path = path(req)
    aor = aor(req.to)
    regs = get_info(service, aor)
    now = System.os_time(:second)

    times = %{
      default: default,
      min: config[:min_time],
      max: config[:max_time],
      now: now,
      outbound: config[:outbound],
      gruu: config[:gruu]
    }

    regs =
      contacts
      |> Enum.reduce(regs, &update_contact(&1, req, path, times, &2))
      |> Enum.sort_by(& &1.updated, :desc)

    case regs do
      [] ->
        store(service, {:del, aor})

      _ ->
        ttl = Enum.max(for reg <- regs, do: reg.expire - now)
        :ok = store(service, {:put, aor, regs, max(ttl, 5)})
    end
  end

  defp update_contact(%URI{domain: "*"}, _req, _path, _times, _regs),
    do: throw({:reply, :invalid_request})

  defp update_contact(%URI{} = contact, req, path, times, regs) do
    aor = aor(req.to)

    if {contact.scheme, contact.user, contact.domain} == aor,
      do: throw({:reply, {:forbidden, "Invalid Contact"}})

    if times.gruu, do: Gruu.check_contact(contact, aor)
    expires = expires(contact, times)
    index = index(contact, times.outbound)
    {cseq, _} = req.cseq
    base = Enum.find(regs, &(&1.index == index))

    if match?(%Contact{}, base) and base.call_id == req.call_id and base.cseq >= cseq,
      do: throw({:reply, {:invalid_request, "Rejected Old CSeq"}})

    regs = Enum.reject(regs, &(&1.index == index))

    if expires == 0 do
      regs
    else
      params = put_param(contact.ext_params, "expires", Integer.to_string(expires))

      reg = %Contact{
        index: index,
        contact: %{contact | ext_params: params},
        updated: System.os_time(:microsecond),
        expire: times.now + expires,
        q: q(contact),
        call_id: req.call_id,
        cseq: cseq,
        origin: origin(req),
        path: path,
        meta: if(base, do: base.meta, else: %{})
      }

      reg = if times.gruu, do: Gruu.update_reg(reg, base, req, aor), else: reg
      [reg | regs]
    end
  end

  defp expires(contact, %{default: default, min: min, max: max}) do
    expires =
      case URI.get_ext_param(contact, "expires") do
        {:ok, value} when is_binary(value) -> parse_int(value) || default
        _ -> default
      end

    cond do
      expires == 0 -> 0
      expires < 3600 and expires < min -> throw({:reply, {:interval_too_brief, min}})
      expires > max -> max
      true -> expires
    end
  end

  defp q(contact) do
    with {:ok, value} when is_binary(value) <- URI.get_ext_param(contact, "q"),
         {q, ""} when q > 0 <- Float.parse(value) do
      q
    else
      _ -> 1.0
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp put_param(params, name, value),
    do: Enum.reject(params, &(Util.ascii_downcase(elem(&1, 0)) == name)) ++ [{name, value}]

  defp del_all(%Message{service: service, cseq: {cseq, _}} = req) do
    aor = aor(req.to)

    if Enum.any?(get_info(service, aor), &(&1.call_id == req.call_id and &1.cseq >= cseq)),
      do: throw({:reply, {:invalid_request, "Rejected Old CSeq"}})

    store(service, {:del, aor})
  end

  defp path(req) do
    Enum.flat_map(Message.header(req, "path"), fn value ->
      case URI.parse(value) do
        {:ok, uris} -> uris
        :error -> throw({:reply, {:invalid_request, "Invalid Path"}})
      end
    end)
  end

  ## ===================================================================
  ## Util
  ## ===================================================================

  defp aor(%URI{scheme: scheme, user: user, domain: domain}), do: {scheme, user, domain}

  # With outbound, contacts are identified by their instance and reg-id
  # (RFC 5626 §6)
  defp index(uri, outbound) do
    case outbound != :none and URI.get_ext_param(uri, "reg-id") do
      {:ok, reg_id} when is_binary(reg_id) ->
        if outbound == false, do: throw({:reply, :first_hop_lacks_outbound})

        case URI.get_ext_param(uri, "+sip.instance") do
          {:ok, instance} when is_binary(instance) -> {:ob, Util.hash(instance), reg_id}
          _ -> index(uri)
        end

      _ ->
        index(uri)
    end
  end

  # Contacts with push parameters (RFC 8599) are identified by them, as
  # their address changes when the device wakes up
  defp index(%URI{scheme: scheme, user: user, domain: domain} = uri) do
    case {URI.get_param(uri, "pn-provider"), URI.get_param(uri, "pn-prid")} do
      {{:ok, provider}, {:ok, prid}} when is_binary(provider) and is_binary(prid) ->
        {:pn, Util.ascii_downcase(provider), prid}

      _ ->
        {scheme, transport(uri), user, domain, uri.port}
    end
  end

  defp transport(%URI{scheme: scheme} = uri) do
    case URI.get_param(uri, "transport") do
      {:ok, transport} when is_binary(transport) -> Util.ascii_downcase(transport)
      _ when scheme == :sips -> "tls"
      _ -> "udp"
    end
  end

  defp origin(%Message{port: %{} = port}), do: {port.transport, port.remote_ip, port.remote_port}
  defp origin(%Message{}), do: nil

  defp contact_origin(%URI{scheme: scheme, domain: domain} = uri) when scheme in [:sip, :sips] do
    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(Util.unbracket(domain))) do
      transport = String.to_existing_atom(transport(uri))
      {transport, ip, uri.port || Caracola.DNS.default_port(transport)}
    end
  rescue
    ArgumentError -> nil
  end

  defp contact_origin(_uri), do: nil

  # With Path, the contact carries it as a Route header
  @doc false
  # The registered contact, with its Path as a Route header
  def make_contact(%Contact{contact: contact, path: []}), do: contact

  def make_contact(%Contact{contact: contact, path: path}) do
    route = path |> URI.encode() |> IO.iodata_to_binary()
    route = Elixir.URI.encode(route, &Elixir.URI.char_unreserved?/1)
    %{contact | headers: [{"route", route} | contact.headers], ext_params: [], ext_headers: []}
  end

  defp store(service, op), do: service.sip_registrar_store(op, service)

  defp config(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> Keyword.get(config, :registrar, [])
      _ -> []
    end
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <- NimbleOptions.validate(Keyword.get(config, :registrar, []), @schema) do
      config = Caracola.Config.add_values(config, :allow, ["REGISTER"])
      opts = Keyword.update!(opts, :service_route, &List.wrap/1)
      {:ok, Keyword.put(config, :registrar, opts)}
    end
  end

  defcb sip_register(req, _call), do: {:reply, request(req)}

  defcb sip_authorize_data(list, req, call) do
    if registered?(req), do: {:cont, [[:register | list], req, call]}, else: :cont
  end

  defcb sip_registrar_store(op, service), do: Store.op(op, service)
end
