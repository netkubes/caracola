defmodule Caracola.Call.Transp do
  @moduledoc false
  # Sending of requests and responses from the call process. Port of
  # NkSIP's nksip_call_uac_transp and nksip_call_uas_transp.

  import Caracola.Util

  alias Caracola.Call.Outbound
  alias Caracola.{DNS, Message, Transport, URI, Util, Via}
  alias Caracola.Transport.Port

  ## ===================================================================
  ## Requests
  ## ===================================================================

  @doc """
  Sends a new request. The destination is the first route, if any, or the
  Request-URI. The Via header (with a new branch) and, if `:contact` is in
  `opts`, the Contact header are generated for the transport used.

  With a strict router as first route (no `lr`), it becomes the
  Request-URI and the original one is moved to the end of the routes.
  """
  @spec send_request(Message.t(), list(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  def send_request(%Message{} = req, opts, config) do
    {dest, req} = destination(req)

    # Plugins can stop the request once its destination is known (see
    # caracola_sending_request/2)
    make = fn port ->
      case req.service.caracola_sending_request(req, port) do
        :ok -> prepare_request(req, port, opts, config)
        {:error, reason} -> throw({:caracola_not_sent, reason})
      end
    end

    result =
      case Util.opt(opts, :route_flow) do
        # Through an outbound flow (RFC 5626)
        %Port{} = flow ->
          Transport.send_message(flow, make)

        nil ->
          Transport.send_message(req.service, plain(dest), make, transport_opts(config, opts))
      end

    case result do
      {:ok, port, msg} -> {:ok, %{msg | port: port}}
      {:error, error} -> {:error, error}
    end
  catch
    {:caracola_not_sent, reason} -> {:error, reason}
  end

  defp destination(%Message{ruri: ruri, routes: []} = req), do: {ruri, req}

  defp destination(%Message{ruri: ruri, routes: [top | rest]} = req) do
    dest = if ruri.scheme == :sips, do: %{top | scheme: :sips}, else: top

    case URI.get_param(top, "lr") do
      {:ok, _} -> {dest, req}
      :error -> {dest, %{req | ruri: plain(top), routes: rest ++ [plain(ruri)]}}
    end
  end

  @doc "Sends again a request through the port used the first time."
  @spec resend_request(Message.t()) :: {:ok, Message.t()} | {:error, term()}
  def resend_request(%Message{port: port} = req) do
    with {:ok, port} <- Transport.send(port, req), do: {:ok, %{req | port: port}}
  end

  @doc """
  Sends a request that must follow the same path as a previous one (ACK for
  non-2xx and CANCEL): same port and same Via branch.
  """
  @spec send_same_path(Message.t(), Message.t()) :: {:ok, Message.t()} | {:error, term()}
  def send_same_path(%Message{} = req, %Message{port: port}) do
    with {:ok, port} <- Transport.send(port, req), do: {:ok, %{req | port: port}}
  end

  defp prepare_request(req, %Port{} = port, opts, config) do
    host = local_host(port.listen_ip, config)

    via = %Via{
      transport: port.transport,
      domain: host,
      port: port.listen_port,
      params: [{"rport", nil}, {"branch", branch(req, opts)} | config[:via_params] || []]
    }

    req =
      req
      |> add_route(port, host, opts)
      |> Map.merge(%{
        vias: [via | req.vias],
        ruri: %{req.ruri | ext_params: [], ext_headers: []}
      })

    if :contact in opts and req.contacts == [] do
      scheme = if req.ruri.scheme == :sips and secure?(port), do: :sips, else: :sip
      contact = instance_contact(contact(scheme, port, host, req.from.user), req, opts, config)
      contact = %{contact | ext_params: contact.ext_params ++ Util.opt(opts, :contact_params, [])}
      %{req | contacts: [contact]}
    else
      req
    end
  end

  # With outbound or GRUU, the Contact has the +sip.instance (RFC 5626
  # §4.1, RFC 5627), a reg-id in REGISTER (with the :reg_id option), and
  # `ob` in dialog-forming requests (RFC 5626 §4.2.1)
  defp instance_contact(contact, %Message{class: {:req, method}} = req, opts, config) do
    supported = config[:supported] || []

    if "outbound" in supported or "gruu" in supported do
      outbound? = "outbound" in supported and Outbound.supported?(req)
      instance = {"+sip.instance", ~s("#{config[:instance_id]}")}

      reg_id =
        case Util.opt(opts, :reg_id) do
          reg_id when outbound? and method == :register and is_integer(reg_id) ->
            [{"reg-id", Integer.to_string(reg_id)}]

          _ ->
            []
        end

      %{contact | params: contact.params ++ ob(outbound?, req), ext_params: [instance | reg_id]}
    else
      contact
    end
  end

  defp ob(true, %Message{class: {:req, method}, to_tag: nil})
       when method in [:invite, :subscribe, :refer, :notify],
       do: [{"ob", nil}]

  defp ob(_outbound?, _req), do: []

  # A stateless proxy derives the branch from the one it received, so that
  # retransmissions get the same one, and marks it to recognize the
  # responses (see stateless?/1)
  defp branch(%Message{vias: [via | _]} = req, opts) do
    if :stateless_via in opts do
      base =
        case Via.get_param(via, "branch") do
          {:ok, "z9hG4bK" <> old} when old != "" ->
            Util.hash({req.service, old})

          _ ->
            Util.hash(
              {req.service, via, req.from_tag, req.to_tag, req.call_id, req.cseq, req.ruri}
            )
        end

      "z9hG4bK" <> base <> "-" <> Util.hash({base, Util.global_id(), :stateless})
    else
      "z9hG4bK" <> Util.uid()
    end
  end

  defp branch(_req, _opts), do: "z9hG4bK" <> Util.uid()

  @doc """
  Returns `true` if the top Via of a response was added by us as a
  stateless proxy.
  """
  @spec stateless?(Message.t()) :: boolean()
  def stateless?(%Message{vias: [via | _]}) do
    with {:ok, "z9hG4bK" <> branch} when is_binary(branch) <- Via.get_param(via, "branch"),
         [base, hash] <- String.split(branch, "-") do
      hash == Util.hash({base, Util.global_id(), :stateless})
    else
      _ -> false
    end
  end

  def stateless?(%Message{}), do: false

  # Record-Route (dialog-creating requests) and Path (REGISTER) pointing to us
  defp add_route(%Message{class: {:req, method}} = req, port, host, opts) do
    cond do
      :record_route in opts and method in [:invite, :subscribe, :notify, :refer] ->
        insert_route(req, "record-route", port, host, opts)

      :path in opts and method == :register ->
        insert_route(req, "path", port, host, opts)

      true ->
        req
    end
  end

  # With an outbound flow, the user is its token, and the Path of the first
  # hop has `ob` (RFC 5626 §5.3)
  defp insert_route(req, header, port, host, opts) do
    uri =
      case Util.opt(opts, :record_flow) do
        {flow, ob?} ->
          uri = route_uri("NkF" <> Outbound.encode_flow(flow), port, host)
          if ob? and header == "path", do: %{uri | params: uri.params ++ [{"ob", nil}]}, else: uri

        nil ->
          route_uri(route_user(req), port, host)
      end

    {:ok, req} = Message.update_header(req, :insert, header, uri)
    req
  end

  # Our routes are identified by the top Via of the request we received,
  # which is also the top Via of the responses we send back
  defp route_user(%Message{vias: vias, service: service}) do
    branch =
      case vias do
        [via | _] -> Via.get_param(via, "branch")
        [] -> nil
      end

    "NkQ" <> Util.hash({Util.global_id(), service, branch})
  end

  defp route_uri(user, port, host) do
    params =
      if port.transport == :udp, do: [], else: [{"transport", Atom.to_string(port.transport)}]

    %URI{
      scheme: :sip,
      user: user,
      domain: host,
      port: port.listen_port,
      params: params ++ [{"lr", nil}]
    }
  end

  defp transport_opts(config, opts) do
    # opts mixes flags and {key, value} pairs
    [udp_max_size: config[:udp_max_size] || 1300, udp_to_tcp: true] ++
      for({key, _} = opt <- opts, key in [:tls, :connect_timeout, :idle_timeout], do: opt) ++
      if(:new_connection in opts, do: [new_connection: true], else: []) ++
      if(config[:tls_client], do: [tls: config[:tls_client]], else: [])
  end

  ## ===================================================================
  ## Responses
  ## ===================================================================

  @doc """
  Sends a response to the request it belongs to (RFC 3261 §18.2.2 and
  RFC 3581). Over TCP and TLS it uses the connection the request came
  from or, if it was closed, a new connection to the address in the Via.
  Over UDP it goes to `maddr`, or to the source address and port (`rport`)
  or Via port, from the socket that received the request.
  """
  @spec send_response(Message.t(), list(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  def send_response(%Message{vias: [via | _], port: %Port{} = port} = resp, opts, config) do
    make = fn port -> prepare_response(resp, port, opts, config) end

    result =
      case port.transport do
        :udp ->
          case Via.get_param(via, "maddr") do
            {:ok, maddr} when is_binary(maddr) ->
              uri = %URI{
                scheme: :sip,
                domain: maddr,
                port: via.port,
                params: [{"transport", "udp"}]
              }

              Transport.send_message(resp.service, uri, make)

            _ ->
              Transport.send_message(%{port | remote_port: response_port(via, port)}, make)
          end

        transport ->
          with {:error, _} <- Transport.send_message(port, make) do
            target = {transport, port.remote_ip, via.port || DNS.default_port(transport)}
            Transport.send_message(resp.service, target, make)
          end
      end

    case result do
      {:ok, port, msg} -> {:ok, %{msg | port: port}}
      {:error, error} -> {:error, error}
    end
  end

  def send_response(%Message{}, _opts, _config), do: {:error, :no_transport}

  @doc "Sends again a response through the port used the first time."
  @spec resend_response(Message.t()) :: {:ok, Message.t()} | {:error, term()}
  def resend_response(%Message{port: %Port{} = port} = resp) do
    with {:ok, port} <- Transport.send(port, resp), do: {:ok, %{resp | port: port}}
  end

  # rport with a value (we add it in UAS.preprocess) or the Via port
  defp response_port(via, port) do
    case Via.get_param(via, "rport") do
      {:ok, rport} when is_binary(rport) -> String.to_integer(rport)
      _ -> via.port || port.remote_port
    end
  end

  defp prepare_response(resp, port, opts, config) do
    host = local_host(port.listen_ip, config)
    resp = update_record_route(resp, port, host)

    if :contact in opts and resp.contacts == [] do
      scheme = if :secure in opts and secure?(port), do: :sips, else: :sip
      %{resp | contacts: [contact(scheme, port, host, resp.to.user)]}
    else
      resp
    end
  end

  # As a proxy, our Record-Route in a response gets the address it is sent
  # from, which may not be the one the request was sent through (IPv4 and
  # IPv6, or another transport): each side of the dialog sees the address it
  # can reach (RFC 5118 §4.2)
  defp update_record_route(%Message{headers: headers} = resp, port, host) do
    user = route_user(resp)

    if Enum.any?(headers, &match?({"record-route", _}, &1)),
      do: %{resp | headers: Enum.map(headers, &update_route(&1, user, port, host))},
      else: resp
  end

  defp update_route({"record-route", value} = header, user, port, host) do
    if String.contains?(value, user),
      do: {"record-route", update_route(value, user, port, host)},
      else: header
  end

  defp update_route({_name, _value} = header, _user, _port, _host), do: header

  defp update_route(value, user, port, host) do
    case URI.parse(value) do
      {:ok, uris} ->
        uris
        |> Enum.map(&if(&1.user == user, do: route_uri(user, port, host), else: &1))
        |> Enum.map_join(", ", &IO.iodata_to_binary(URI.encode(&1)))

      :error ->
        value
    end
  end

  ## ===================================================================
  ## Util
  ## ===================================================================

  defp contact(scheme, %Port{transport: transport, listen_port: listen_port}, host, user) do
    params =
      case {scheme, transport} do
        {:sip, :udp} -> []
        {:sips, :tls} -> []
        # RFC 7118 §5.2: WSS is a sips URI with transport ws
        {:sips, :wss} -> [{"transport", "ws"}]
        _ -> [{"transport", Atom.to_string(transport)}]
      end

    %URI{scheme: scheme, user: user, domain: host, port: listen_port, params: params}
  end

  defp secure?(%Port{transport: transport}), do: transport in [:tls, :wss]

  defp plain(uri), do: %{uri | disp: nil, headers: [], ext_params: [], ext_headers: []}
end
