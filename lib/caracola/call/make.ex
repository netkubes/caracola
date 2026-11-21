defmodule Caracola.Call.Make do
  @moduledoc false
  # Generation of requests. Port of NkSIP's nksip_call_uac_make.

  alias Caracola.{Call, Message, URI, Util}
  alias Caracola.Call.SessionTimer

  @header_opts [
    :from,
    :to,
    :content_type,
    :require,
    :supported,
    :expires,
    :contact,
    :refer_to,
    :sip_if_match,
    :route,
    :reason,
    :event
  ]

  # Options used later, when sending or when the response arrives
  @flags [
    :contact,
    :async,
    :get_request,
    :no_dialog,
    :no_auto_expire,
    :auto_2xx_ack,
    :record_route,
    :path,
    :new_connection,
    :follow_redirects
  ]
  @keyed [
    :callback,
    :get_meta,
    :timeout,
    :tls,
    :connect_timeout,
    :idle_timeout,
    :password,
    :prack_callback,
    :refer_subscription,
    :reg_id,
    :contact_params,
    :record_flow,
    :route_flow
  ]

  @dialog_methods [:invite, :subscribe, :notify, :refer, :update]

  @doc """
  Generates a request. Returns it with the options to use when sending it.
  """
  @spec request(Call.t(), Message.method(), binary() | URI.t(), list()) ::
          {:ok, Message.t(), list()} | {:error, term()}
  def request(%Call{} = call, method, uri, opts) do
    opts = default_opts(method) ++ opts
    opts = Enum.flat_map(opts, &expand_opt(method, &1))

    with {:ok, ruri} <- parse_ruri(uri),
         {:ok, from} <- default_from(call.config),
         req = base(call, method, ruri, from),
         {:ok, req} <- default_routes(req, call.config),
         {:ok, req} <- uri_headers(req, ruri.headers),
         {:ok, req, send_opts} <- apply_opts(opts, req, call.config, []) do
      req = from_tag(req)
      req = if method == :register, do: to_as_from(req, opts), else: req
      {:ok, req, auto_contact(method, req, send_opts)}
    end
  end

  # A From given in the options without tag gets a new one (as NkSIP)
  defp from_tag(%Message{from_tag: nil, from: from} = req) do
    from_tag = Util.uid()

    %{
      req
      | from: %{from | ext_params: from.ext_params ++ [{"tag", from_tag}]},
        from_tag: from_tag
    }
  end

  defp from_tag(req), do: req

  # The To of a REGISTER is the AOR, the From by default
  defp to_as_from(req, opts) do
    if Util.opt?(opts, :to) do
      req
    else
      params = Enum.reject(req.from.ext_params, &(elem(&1, 0) == "tag"))
      %{req | to: %{req.from | ext_params: params}, to_tag: nil}
    end
  end

  @doc """
  Applies the options of a proxy (header changes and flags) to a request
  being proxied. Returns it with the options to use when sending it.
  """
  @spec proxy(Message.t(), list(), keyword()) :: {:ok, Message.t(), list()} | {:error, term()}
  def proxy(%Message{} = req, opts, config), do: apply_opts(opts, req, config, [])

  # Headers always added (as NkSIP's nksip_uac)
  defp default_opts(:invite), do: [:supported, :allow, :allow_event, :recv_info]

  defp default_opts(method) when method in [:options, :register, :subscribe],
    do: [:supported, :allow, :allow_event]

  defp default_opts(:update), do: [:supported, :accept, :allow]
  defp default_opts(_method), do: []

  # Shortcuts for REGISTER
  defp expand_opt(:register, :unregister_all), do: [contact: "*", expires: 0]
  defp expand_opt(:register, :unregister), do: [:contact, expires: 0]
  defp expand_opt(_method, opt), do: [opt]

  defp base(call, method, ruri, from) do
    from_tag = Util.uid()

    %Message{
      class: {:req, method},
      service: call.service,
      id: Util.uid(),
      ruri: %{ruri | disp: nil, headers: [], ext_params: [], ext_headers: []},
      from: %{from | ext_params: from.ext_params ++ [{"tag", from_tag}]},
      from_tag: from_tag,
      to: %URI{scheme: ruri.scheme, user: ruri.user, domain: ruri.domain},
      call_id: call.call_id,
      cseq: {Util.next_cseq(), method},
      max_forwards: 70
    }
  end

  # Requests that can create a dialog need a Contact
  defp auto_contact(method, req, send_opts) do
    if method in @dialog_methods and req.contacts == [] and :contact not in send_opts,
      do: [:contact | send_opts],
      else: send_opts
  end

  defp parse_ruri(%URI{scheme: scheme} = uri) when scheme in [:sip, :sips, :tel], do: {:ok, uri}

  defp parse_ruri(bin) when is_binary(bin) do
    case URI.parse(bin) do
      {:ok, [uri]} -> parse_ruri(uri)
      _ -> {:error, :invalid_uri}
    end
  end

  defp parse_ruri(_), do: {:error, :invalid_uri}

  defp default_from(config) do
    case URI.parse(config[:from] || "<sip:user@caracola>") do
      {:ok, [from]} -> {:ok, from}
      _ -> {:error, {:invalid, "from"}}
    end
  end

  defp default_routes(req, config) do
    case config[:route] || [] do
      [] -> {:ok, req}
      routes -> Message.update_header(req, :replace, "route", routes)
    end
  end

  @doc false
  # Headers in the Request-URI (sip:a@b?subject=hi)
  def uri_headers(req, headers) do
    Enum.reduce_while(headers, {:ok, req}, fn {name, value}, {:ok, req} ->
      case Message.update_header(req, :add, name, Elixir.URI.decode(value || "")) do
        {:ok, req} -> {:cont, {:ok, req}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_opts([], req, _config, send_opts), do: {:ok, req, Enum.reverse(send_opts)}

  defp apply_opts([opt | rest], req, config, send_opts) do
    case apply_opt(opt, req, config) do
      {:ok, req} -> apply_opts(rest, req, config, send_opts)
      :send -> apply_opts(rest, req, config, [opt | send_opts])
      :ignore -> apply_opts(rest, req, config, send_opts)
      {:error, error} -> {:error, error}
    end
  end

  defp apply_opt({op, name, value}, req, _config) when op in [:add, :replace, :insert],
    do: Message.update_header(req, op, name, value)

  defp apply_opt({:remove, name}, req, _config) when is_binary(name) or is_atom(name),
    do: {:ok, Message.remove_header(req, name)}

  defp apply_opt({name, value}, req, _config) when name in @header_opts,
    do: Message.update_header(req, :replace, name, value)

  defp apply_opt({:body, body}, req, _config) when is_binary(body), do: {:ok, %{req | body: body}}

  defp apply_opt({:body, %Caracola.SDP{} = sdp}, req, _config),
    do: {:ok, Caracola.SDP.put_body(req, sdp)}

  defp apply_opt({:cseq_num, num}, %Message{cseq: {_, method}} = req, _config)
       when is_integer(num) and num > 0 and num < 0x100000000,
       do: {:ok, %{req | cseq: {num, method}}}

  defp apply_opt({:call_id, call_id}, _req, _config) when is_binary(call_id), do: :ignore

  # Session timers
  defp apply_opt({:session_expires, se}, req, config) when is_integer(se),
    do: apply_opt({:session_expires, {se, nil}}, req, config)

  defp apply_opt({:session_expires, {se, refresher}}, req, config)
       when is_integer(se) and refresher in [nil, :uac, :uas] do
    if se < (config[:min_se] || 90),
      do: {:error, {:invalid_config, :session_expires}},
      else:
        Message.update_header(
          req,
          :replace,
          "session-expires",
          SessionTimer.header(se, refresher)
        )
  end

  defp apply_opt({:min_se, min_se}, req, _config) when is_integer(min_se) and min_se > 0,
    do: Message.update_header(req, :replace, "min-se", min_se)

  defp apply_opt({:subscription_state, state}, %Message{class: {:req, :notify}} = req, _config) do
    case Caracola.Subscription.encode_state(state) do
      {:ok, value} -> Message.update_header(req, :replace, "subscription-state", value)
      :error -> {:error, {:invalid_config, :subscription_state}}
    end
  end

  defp apply_opt({:callback, fun}, _req, _config) when is_function(fun, 1), do: :send
  defp apply_opt({:get_meta, list}, _req, _config) when is_list(list), do: :send

  defp apply_opt({key, _}, _req, _config)
       when key in @keyed and key not in [:callback, :get_meta], do: :send

  defp apply_opt(flag, _req, _config) when flag in @flags, do: :send

  defp apply_opt(:user_agent, req, _config),
    do: Message.update_header(req, :replace, "user-agent", "Caracola")

  defp apply_opt(:supported, req, config),
    do: Message.update_header(req, :replace, "supported", config[:supported] || [])

  defp apply_opt(:allow, req, config),
    do: Message.update_header(req, :replace, "allow", config[:allow] || [])

  defp apply_opt(:date, req, _config),
    do: Message.update_header(req, :replace, "date", Caracola.Date.now())

  defp apply_opt(:accept, %Message{class: {:req, method}} = req, config) do
    accept =
      case config[:accept] do
        nil when method in [:invite, :update, :prack] -> "application/sdp"
        nil -> "*/*"
        accept -> accept
      end

    Message.update_header(req, :replace, "accept", accept)
  end

  defp apply_opt(:recv_info, req, config) do
    case config[:info_packages] do
      nil -> :ignore
      packages -> Message.update_header(req, :replace, "recv-info", Enum.join(packages, ", "))
    end
  end

  defp apply_opt(:allow_event, req, config) do
    case config[:events] || [] do
      [] -> :ignore
      events -> Message.update_header(req, :replace, "allow-event", events)
    end
  end

  defp apply_opt(opt, _req, _config),
    do: {:error, {:invalid_config, if(is_tuple(opt), do: elem(opt, 0), else: opt)}}

  @doc """
  Generates a CANCEL for an INVITE (RFC 3261 §9.1): same Request-URI,
  Call-ID, From, To, CSeq number, Route and top Via.
  """
  @spec cancel(Message.t(), list()) :: Message.t()
  def cancel(%Message{vias: [via | _], cseq: {cseq, _}} = req, opts) do
    headers =
      case Util.opt(opts, :reason) do
        nil -> []
        reason -> [{"reason", reason}]
      end

    %{
      clean(req)
      | class: {:req, :cancel},
        id: Util.uid(),
        cseq: {cseq, :cancel},
        vias: [via],
        routes: req.routes,
        headers: headers
    }
  end

  @doc """
  Generates the ACK for a non-2xx final response to an INVITE (RFC 3261
  §17.1.1.3): as the INVITE, with the To of the response and the top Via.
  """
  @spec ack(Message.t(), Message.t()) :: Message.t()
  def ack(%Message{vias: [via | _], cseq: {cseq, _}} = req, %Message{to: to, to_tag: to_tag}) do
    %{
      clean(req)
      | class: {:req, :ack},
        id: Util.uid(),
        cseq: {cseq, :ack},
        vias: [via],
        to: to,
        to_tag: to_tag,
        routes: req.routes
    }
  end

  defp clean(req) do
    %{
      req
      | max_forwards: 70,
        routes: [],
        contacts: [],
        headers: [],
        content_type: nil,
        require: [],
        supported: [],
        expires: nil,
        event: nil,
        body: ""
    }
  end
end
