defmodule Caracola.Call.Proxy do
  @moduledoc false
  # Proxying of requests (RFC 3261 §16): checks, options, stateless
  # forwarding of requests and responses. Stateful proxying is done by
  # Caracola.Call.Fork. Port of NkSIP's nksip_call_proxy.

  require Logger

  alias Caracola.Call.{Make, Outbound, Trans, Transp}
  alias Caracola.{DNS, Message, Tokens, Transport, URI, Via}

  @typedoc """
  Destinations of a proxied request: a URI, a binary with one or more
  URIs, or a list of them (tried in parallel). A list with nested lists is
  a list of groups tried in order, each one in parallel.
  """
  @type uri_set :: URI.t() | binary() | [URI.t() | binary() | [URI.t() | binary()]]

  @doc false
  # Returns `{:fork, request, uri_set, opts}` to proxy statefully, `:noreply`
  # if the request has been sent statelessly, or `{:reply, sipreply}`
  def route(uris, opts, %Trans{request: req, method: method}, call) do
    with {:ok, uri_set} <- check_uris(uri_set(uris)),
         {:ok, req} <- check_request(req, method, opts),
         {:ok, opts} <- Outbound.proxy_opts(req, opts, call.config) do
      if :stateless in opts,
        do: route_stateless(req, hd(hd(uri_set)), opts, call),
        else: {:fork, req, uri_set, Enum.reject(opts, &(&1 == :stateless))}
    end
  end

  defp check_uris([[]]), do: {:reply, :temporarily_unavailable}
  defp check_uris(uri_set), do: {:ok, uri_set}

  # Max-Forwards (RFC 3261 §16.3), Proxy-Require and Path
  defp check_request(%Message{max_forwards: 0}, :options, _opts),
    do: {:reply, {:ok, [:supported, :accept, :allow, reason_phrase: "Max Forwards"]}}

  defp check_request(%Message{max_forwards: 0}, _method, _opts), do: {:reply, :too_many_hops}

  defp check_request(%Message{max_forwards: forwards} = req, method, opts) do
    unsupported = if method == :ack, do: [], else: proxy_require(req)

    cond do
      unsupported != [] ->
        {:reply, {:bad_extension, Enum.join(unsupported, ",")}}

      method == :register and :path in opts and "path" not in req.supported ->
        {:reply, {:extension_required, "path"}}

      true ->
        {:ok, %{req | max_forwards: (forwards || 70) - 1}}
    end
  end

  # No extension is supported for proxies
  defp proxy_require(req) do
    for value <- Message.header(req, "proxy-require"),
        {:ok, tokens} <- [Tokens.parse(value)],
        {name, _} <- tokens,
        do: name
  end

  @doc false
  # Applies the headers of the destination URI (like the Route of a
  # registration with Path) and the proxy options to a request to send to
  # `uri`, removing the routes pointing to us
  def prepare(%Message{} = req, %URI{} = uri, opts, call) do
    req = %{req | ruri: %{uri | headers: []}, id: Caracola.Util.uid(), dialog_id: nil}

    with {:ok, req} <- Make.uri_headers(req, uri.headers),
         {:ok, req, send_opts} <- Make.proxy(req, opts, call.config) do
      routes = Enum.drop_while(req.routes, &Transport.local?(call.service, &1, call.config))
      {:ok, %{req | routes: routes}, send_opts}
    end
  end

  defp route_stateless(req, uri, opts, call) do
    case prepare(req, uri, Enum.reject(opts, &(&1 == :stateless)), call) do
      {:ok, req, send_opts} ->
        case Transp.send_request(req, [:stateless_via | send_opts], call.config) do
          {:ok, _} -> :ok
          {:error, error} -> Logger.notice("stateless proxy could not send: #{inspect(error)}")
        end

        :noreply

      {:error, error} ->
        Logger.warning("invalid proxy options #{inspect(opts)}: #{inspect(error)}")
        {:reply, {:internal_error, "Proxy Options"}}
    end
  end

  @doc false
  # A response for a request sent statelessly: it goes to the next Via
  def response_stateless(%Message{class: {:resp, code, _}}, call) when code < 101, do: call

  def response_stateless(%Message{vias: [_, via | vias]} = resp, call) do
    with {:ok, ip} <- received(via),
         {:ok, _} <-
           Transport.send(call.service, {via.transport, ip, response_port(via)}, %{
             resp
             | vias: [via | vias]
           }) do
      call
    else
      error ->
        Logger.notice("stateless proxy could not send response: #{inspect(error)}")
        call
    end
  end

  def response_stateless(%Message{}, call) do
    Logger.notice("stateless proxy could not send response: no Via")
    call
  end

  defp received(via) do
    with {:ok, host} when is_binary(host) <- Via.get_param(via, "received"),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip}
    else
      _ -> {:error, :no_received}
    end
  end

  defp response_port(via) do
    case Via.get_param(via, "rport") do
      {:ok, rport} when is_binary(rport) -> String.to_integer(rport)
      _ -> via.port || DNS.default_port(via.transport)
    end
  end

  ## ===================================================================
  ## URI sets
  ## ===================================================================

  @doc """
  Normalizes a URI set into a list of groups of URIs (`[[]]` if there is
  no valid URI).
  """
  @spec uri_set(uri_set() | term()) :: [[URI.t()]]
  def uri_set(%URI{} = uri), do: [[plain(uri)]]
  def uri_set(bin) when is_binary(bin), do: [parse(bin)]
  def uri_set(list) when is_list(list), do: normalize(:single, list, [], [])
  def uri_set(_other), do: [[]]

  defp normalize(:single, [item | rest], acc, groups) when is_binary(item) or is_struct(item),
    do: normalize(:single, rest, acc ++ parse(item), groups)

  defp normalize(:single, [item | _] = list, acc, groups) when is_list(item),
    do: normalize(:multi, list, acc, groups)

  defp normalize(:multi, [item | rest], acc, groups)
       when is_binary(item) or is_struct(item) or is_list(item),
       do: normalize(:multi, rest, [], groups ++ group(acc) ++ [parse(item)])

  defp normalize(mode, [_ | rest], acc, groups), do: normalize(mode, rest, acc, groups)
  defp normalize(_mode, [], [], []), do: [[]]
  defp normalize(_mode, [], acc, groups), do: groups ++ group(acc)

  defp group([]), do: []
  defp group(acc), do: [acc]

  defp parse(%URI{} = uri), do: [plain(uri)]
  defp parse(list) when is_list(list), do: Enum.flat_map(list, &parse/1)

  defp parse(bin) when is_binary(bin) do
    case URI.parse(bin) do
      {:ok, uris} -> Enum.map(uris, &plain/1)
      :error -> []
    end
  end

  defp parse(_other), do: []

  defp plain(uri), do: %{uri | ext_params: [], ext_headers: []}
end
