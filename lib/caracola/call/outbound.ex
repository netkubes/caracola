defmodule Caracola.Call.Outbound do
  @moduledoc false
  # Client-initiated connections (RFC 5626), active when the service
  # supports "outbound" (see Caracola.Outbound). Port of NkSIP's
  # nksip_outbound.
  #
  # A flow is the connection (or UDP address) a request came from. Edge
  # proxies and registrars add Record-Route and Path headers with a flow
  # token (user "NkF<token>"), so that requests for the UA are sent back
  # through the same flow. Tokens are signed: an invalid one is rejected
  # with 403, and one whose connection is down with 430 (Flow Failed).

  alias Caracola.{Message, Transport, URI, Util}
  alias Caracola.Transport.Port

  @doc false
  def enabled?(config), do: "outbound" in (config[:supported] || [])

  @doc false
  def supported?(%Message{} = req), do: "outbound" in req.supported or "outbound" in req.require

  ## ===================================================================
  ## Flow tokens
  ## ===================================================================

  @doc false
  # Token of the flow of a port
  @spec encode_flow(Port.t()) :: String.t()
  def encode_flow(%Port{} = port) do
    data =
      :erlang.term_to_binary(
        {port.transport, port.remote_ip, port.remote_port, port.listen_port, port.pid}
      )

    Base.url_encode64(data <> mac(data), padding: false)
  end

  @doc false
  # Port of a flow token: :invalid or :flow_failed (its connection is down)
  @spec decode_flow(String.t()) :: {:ok, Port.t()} | {:error, :invalid | :flow_failed}
  def decode_flow(token) do
    with {:ok, bin} when byte_size(bin) > 16 <- Base.url_decode64(token, padding: false),
         size = byte_size(bin) - 16,
         <<data::binary-size(^size), mac::binary>> = bin,
         true <- :crypto.hash_equals(mac, mac(data)),
         {transport, ip, port, _listen, pid} <- :erlang.binary_to_term(data, [:safe]) do
      flow_port(transport, ip, port, pid)
    else
      _ -> {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp mac(data) do
    :crypto.mac(:hmac, :sha256, Util.global_id(), data) |> binary_part(0, 16)
  end

  # UDP flows are the listener socket with the remote address
  defp flow_port(:udp, ip, remote_port, pid) do
    case Transport.listener_port(pid) do
      {:ok, listener} -> {:ok, %{listener | remote_ip: ip, remote_port: remote_port}}
      :error -> {:error, :flow_failed}
    end
  end

  defp flow_port(_transport, _ip, _remote_port, pid) do
    case Transport.connection_port(pid) do
      {:ok, port} -> {:ok, port}
      :error -> {:error, :flow_failed}
    end
  end

  @doc false
  # The same flow (transport and remote address)
  def same_flow?(%Port{} = a, %Port{} = b),
    do: {a.transport, a.remote_ip, a.remote_port} == {b.transport, b.remote_ip, b.remote_port}

  ## ===================================================================
  ## Proxy
  ## ===================================================================

  @doc false
  # Options of a proxied request (RFC 5626 §5.3): `{:record_flow, {port,
  # ob?}}` to use a flow token in our Record-Route or Path (with `ob` for
  # Path if we are the first hop), and `{:route_flow, port}` to send the
  # request through a flow
  @spec proxy_opts(Message.t(), list(), keyword()) :: {:ok, list()} | {:reply, term()}
  def proxy_opts(%Message{class: {:req, :register}} = req, opts, config) do
    with true <- enabled?(config) and :path in opts and "path" in req.supported,
         [contact] <- req.contacts,
         {:ok, _} <- URI.get_ext_param(contact, "reg-id"),
         %Port{remote_ip: ip} = flow when ip != nil <- req.port do
      {:ok, [{:record_flow, {flow, length(req.vias) == 1}} | opts]}
    else
      _ -> {:ok, opts}
    end
  end

  def proxy_opts(%Message{} = req, opts, config) do
    if enabled?(config) and supported?(req) do
      with {:ok, opts} <- route_opts(req, opts, req.routes, config) do
        {:ok, contact_opts(req, opts)}
      end
    else
      {:ok, opts}
    end
  end

  # The first local routes: one with a flow token is followed (or, if the
  # request came through that flow, recorded), and one with `ob` records
  # the flow of the request
  defp route_opts(_req, opts, [], _config), do: {:ok, opts}

  defp route_opts(req, opts, [route | rest], config) do
    cond do
      not Transport.local?(req.service, route, config) -> {:ok, opts}
      match?("NkF" <> _, route.user) -> flow_opts(req, opts, route)
      ob?(route) -> {:ok, ob_opts(req, opts)}
      true -> route_opts(req, opts, rest, config)
    end
  end

  defp flow_opts(req, opts, %URI{user: "NkF" <> token} = route) do
    case decode_flow(token) do
      {:ok, flow} ->
        cond do
          same_flow?(req.port, flow) -> {:ok, [{:record_flow, {flow, false}} | opts]}
          ob?(route) -> {:ok, [{:route_flow, flow}, {:record_flow, {flow, false}} | opts]}
          true -> {:ok, [{:route_flow, flow} | opts]}
        end

      {:error, :flow_failed} ->
        {:reply, :flow_failed}

      {:error, :invalid} ->
        {:reply, {:forbidden, "Invalid Flow Token"}}
    end
  end

  defp ob?(uri), do: URI.get_param(uri, "ob") != :error

  defp ob_opts(req, opts) do
    if match?(%Port{remote_ip: ip} when ip != nil, req.port),
      do: [{:record_flow, {req.port, false}} | opts],
      else: opts
  end

  # A Contact with `ob` asks to use the same flow for the dialog
  defp contact_opts(req, opts) do
    with false <- Util.opt?(opts, :record_flow),
         [contact | _] <- req.contacts,
         {:ok, _} <- URI.get_param(contact, "ob"),
         %Port{remote_ip: ip} when ip != nil <- req.port do
      [{:record_flow, {req.port, false}} | opts]
    else
      _ -> opts
    end
  end

  ## ===================================================================
  ## Registrar
  ## ===================================================================

  @doc false
  # Outbound processing of a REGISTER at the registrar (RFC 5626 §6):
  # `:none` if not supported, or if the first hop supports outbound. If we
  # are the first hop, a Path with our flow is added.
  @spec registrar(Message.t(), keyword()) :: {boolean() | :none, Message.t()}
  def registrar(%Message{} = req, config) do
    cond do
      not (enabled?(config) and supported?(req)) ->
        {:none, req}

      length(req.vias) == 1 and match?(%Port{remote_ip: ip} when ip != nil, req.port) ->
        port = req.port
        host = Util.local_host(port.listen_ip, config)

        params =
          if port.transport == :udp,
            do: [],
            else: [{"transport", Atom.to_string(port.transport)}]

        path = %URI{
          user: "NkF" <> encode_flow(port),
          domain: host,
          port: port.listen_port,
          params: params ++ [{"lr", nil}, {"ob", nil}]
        }

        {:ok, req} = Message.update_header(req, :insert, "path", path)
        {true, req}

      true ->
        {first_hop_ob?(req), req}
    end
  end

  # The last Path is the first hop
  defp first_hop_ob?(req) do
    paths =
      Enum.flat_map(Message.header(req, "path"), fn value ->
        case URI.parse(value) do
          {:ok, uris} -> uris
          :error -> []
        end
      end)

    case List.last(paths) do
      nil -> false
      path -> ob?(path)
    end
  end

  @doc false
  # Only one reg-id is allowed in a REGISTER (RFC 5626 §6)
  def check_reg_ids(contacts) do
    with_reg_id =
      Enum.filter(contacts, fn contact ->
        URI.get_ext_param(contact, "reg-id") != :error and
          URI.get_ext_param(contact, "expires") != {:ok, "0"}
      end)

    if length(with_reg_id) > 1, do: {:error, "Several 'reg-id' Options"}, else: :ok
  end
end
