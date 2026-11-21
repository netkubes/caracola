defmodule Caracola do
  @moduledoc """
  `Malla.Plugin` providing a SIP stack to a `Malla.Service`.

  ```
  defmodule MyUA do
    use Malla.Service,
      plugins: [Caracola],
      sip: [listen: "sip:all:5060, <sip:all:5061;transport=tls>"]

    defcb sip_options(_req, _call), do: {:reply, :ok}
  end
  ```

  Configuration goes under the `:sip` key; see `Caracola.Config` for the
  options. A missing `:sip` key is equivalent to `sip: []` (all defaults).

  ## Callbacks

  Incoming requests go through the `sip_*` callbacks, which services can
  implement with `defcb` (returning `:cont` to fall back to the default):

    * `sip_authorize(auth_list, req, call)` - `:ok` (default), `:forbidden`,
      `:authenticate`, `{:authenticate, realm}`, `:proxy_authenticate` or
      `{:proxy_authenticate, realm}`. It is called first with an empty
      list and, if the result is not `:ok`, again with the authorization
      list: `:dialog` if the request comes from an authorized origin of its
      dialog (see `Caracola.Dialog.authorized/1`), and
      `{{:digest, realm}, result}` for the credentials of each realm, where
      `result` is `true`, `false` (wrong password or unknown user) or
      `:invalid` (unknown or expired nonce, or invalid credentials).
    * `sip_get_user_pass(user, realm, req, call)` - the password of a user
      (a binary, or an HA1 as `{:ha1, hex}` for MD5 or `{:ha1, algorithm, hex}`,
      see `Caracola.Digest.ha1/4`), `true` to
      accept it without checking or `false` (default) if unknown.
    * `sip_route(scheme, user, domain, req, call)` - `:process` (default),
      `:process_stateless`, `{:reply, reply}`, `{:reply_stateless, reply}`,
      or to proxy the request: `:proxy` (to the Request-URI),
      `{:proxy, uri_set}` or `{:proxy, uri_set, opts}` (`uri_set` can be
      `:ruri`, see [Proxies](07-proxy.md)), and the same with
      `:proxy_stateless`. `:noreply` routes the request later, with
      `route/2` (not for ACK and CANCEL). Proxy options are the header options of
      `Caracola.UAC` plus `:record_route`, `:path` and `:follow_redirects`.
    * `sip_invite`, `sip_reinvite`, `sip_bye`, `sip_options`, `sip_register`,
      `sip_info`, `sip_message`, `sip_update`, `sip_subscribe`,
      `sip_resubscribe`, `sip_notify`, `sip_refer`, `sip_publish` and
      `sip_prack`, called as `fun(req, call)` - `{:reply, reply}` or
      `:noreply`, to reply later with `reply/2`.
    * `sip_unsolicited_notify(req, call)` - a NOTIFY outside of any
      dialog or subscription, as the message waiting (`message-summary`)
      ones many PBXs send to registered phones. Same results as above; the
      default replies 481, as RFC 6665 requires. Accepting it creates no
      dialog.
    * `sip_ack(req, call)` and `sip_cancel(invite_req, cancel_req, call)` -
      notifications, the result is ignored.
    * `sip_dialog_update(event, dialog, call)` - a `Caracola.Dialog` has
      changed. `event` is `:start`, `{:invite_status, status}` (see
      `Caracola.Dialog.Invite`; `{:stop, reason}` when the INVITE usage
      ends, and a dialog created by a provisional response gets its first
      `:proceeding_uac` or `:proceeding_uas` too), `:target_update`,
      `:invite_timeout`, `{:invite_refresh, local_sdp}` (session timers: time
      to refresh the session, see `Caracola.SessionTimers`),
      `{:subscription_status, status, subscription}` (see
      `Caracola.Subscription`) or `:stop`. The result is ignored.
    * `sip_session_update(event, dialog, call)` - the session of a dialog has
      changed: `{:start, local_sdp, remote_sdp}`,
      `{:update, local_sdp, remote_sdp}` or `:stop`. The result is ignored.

  Replies are described in `Caracola.Reply`. To send requests, see
  `Caracola.UAC`.
  """

  use Malla.Plugin

  alias Caracola.{Call, DNS, Message, Transport, URI}

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Replies to a request received in a `sip_*` callback that returned
  `:noreply`. Must be called from another process.
  """
  @spec reply(Message.t(), Caracola.Reply.sipreply()) :: :ok | {:error, term()}
  def reply(%Message{class: {:req, _}, service: service, call_id: call_id, id: id}, sipreply) do
    if Call.find(service, call_id) == self(),
      do: {:error, :looped_process},
      else: Call.work(service, call_id, {:reply, id, sipreply})
  end

  @doc """
  Routes a request received in `sip_route/5`, that returned `:noreply`:
  `route` is any other result of `sip_route/5`. Must be called from
  another process. Returns an error if the request is gone (for example,
  it was cancelled or timed out).
  """
  @spec route(Message.t(), term()) :: :ok | {:error, term()}
  def route(%Message{class: {:req, _}, service: service, call_id: call_id, id: id}, route) do
    if Call.find(service, call_id) == self(),
      do: {:error, :looped_process},
      else: Call.work(service, call_id, {:route, id, route})
  end

  @doc "Returns the listeners of a service."
  @spec listeners(module()) :: [Transport.Port.t()]
  def listeners(service), do: Transport.listeners(service)

  @doc """
  Returns `true` if the SIP part of a service is ready: the service is
  running, and its call processes and all its listeners have started.

  Malla starts the processes of the plugins in the background, so they are
  not ready yet when `start_link` returns. See `wait_ready/2`.
  """
  @spec ready?(module()) :: boolean()
  def ready?(service) do
    with true <- Malla.Service.is_ready?(service),
         true <- Process.whereis(Call.registry(service)) != nil,
         true <- Process.whereis(Call.supervisor(service)) != nil,
         {:ok, listen} <- parse_listen(Call.config(service)[:listen]) do
      length(listeners(service)) >= length(listen)
    else
      _ -> false
    end
  end

  @doc """
  Waits until the SIP part of a service is ready (see `ready?/1`), for up
  to `timeout` milliseconds (5 seconds by default). Call it after starting
  a service, before sending requests with it:

      {:ok, _} = MyUA.start_link()
      :ok = Caracola.wait_ready(MyUA)
  """
  @spec wait_ready(module(), non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_ready(service, timeout \\ 5_000) do
    wait_ready_until(service, System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_ready_until(service, deadline) do
    cond do
      ready?(service) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(10)
        wait_ready_until(service, deadline)
    end
  end

  ## ===================================================================
  ## Plugin callbacks
  ## ===================================================================

  @impl true
  def plugin_config(srv_id, config) do
    with {:ok, opts} <- Caracola.Config.validate(Keyword.get(config, :sip, [])),
         {:ok, _} <- parse_listen(opts[:listen]) do
      opts = Keyword.put_new_lazy(opts, :instance_id, fn -> instance_id(srv_id) end)
      {:ok, Keyword.put(config, :sip, opts)}
    end
  end

  # A UUID (version 5 like) from the service and node names, stable across
  # restarts (RFC 5626 §4.1)
  defp instance_id(srv_id) do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48, _::binary>> =
      :crypto.hash(:sha, :erlang.term_to_binary({srv_id, node()}))

    uuid =
      :io_lib.format("~8.16.0b-~4.16.0b-5~3.16.0b-~4.16.0b-~12.16.0b", [a, b, c, 0x8000 + d, e])

    "<urn:uuid:#{uuid}>"
  end

  @impl true
  def plugin_start(srv_id, config) do
    sip = Keyword.get(config, :sip, [])
    {:ok, listeners} = parse_listen(sip[:listen])

    listeners =
      for {transport, ip, port, path} <- listeners do
        opts = [ip: ip, port: port, path: path, handler: {Call, srv_id}, tls: sip[:tls] || []]
        Transport.listener_spec(srv_id, transport, opts)
      end

    {:ok, children: Call.children(srv_id) ++ listeners}
  end

  @impl true
  def plugin_updated(_srv_id, old_config, new_config) do
    if old_config[:sip] == new_config[:sip],
      do: :ok,
      else: {:ok, restart: true}
  end

  # "sip:all:5060, <sip:127.0.0.1:0/ws;transport=ws>" ->
  #   [{:udp, ip, 5060, nil}, {:ws, ip, 0, "/ws"}]
  defp parse_listen(nil), do: {:ok, []}

  defp parse_listen(listen) do
    case URI.parse(listen) do
      {:ok, uris} -> listen_targets(uris, listen, [])
      :error -> {:error, {:invalid_listen, listen}}
    end
  end

  defp listen_targets([], _listen, acc), do: {:ok, acc}

  defp listen_targets([uri | rest], listen, acc) do
    case DNS.resolve(uri, listen: true, cache: false) do
      {:ok, [_ | _] = targets} ->
        # Without port, the default one of the transport
        targets =
          for {t, ip, _} <- targets, do: {t, ip, uri.port || DNS.default_port(t), uri.path}

        listen_targets(rest, listen, acc ++ targets)

      _ ->
        {:error, {:invalid_listen, listen}}
    end
  end

  ## ===================================================================
  ## Default callbacks
  ## ===================================================================

  defcb sip_authorize(_auth_list, _req, _call), do: :ok

  defcb sip_get_user_pass(_user, _realm, _req, _call), do: false

  # Plugins can add values to the authorization list
  defcb sip_authorize_data(list, _req, _call), do: list

  # Internal hook: plugins see every callback to the service before it is
  # called. `:cont` calls it, `{:done, result}` returns `result` instead.
  defcb caracola_callback(_fun, _args), do: :cont

  defcb sip_route(_scheme, _user, _domain, _req, _call), do: :process

  defcb sip_options(_req, _call),
    do: {:reply, {:ok, [:contact, :allow, :allow_event, :accept, :supported]}}

  defcb sip_register(_req, call), do: {:reply, {:method_not_allowed, call.config[:allow] || []}}

  defcb sip_invite(_req, _call), do: {:reply, :decline}

  defcb sip_reinvite(req, call), do: call.service.sip_invite(req, call)

  defcb sip_cancel(_invite_req, _cancel_req, _call), do: :ok

  defcb sip_ack(_req, _call), do: :ok

  defcb sip_bye(_req, _call), do: {:reply, :ok}

  defcb sip_update(_req, _call), do: {:reply, :decline}

  defcb sip_subscribe(_req, _call), do: {:reply, :decline}

  defcb sip_resubscribe(_req, _call), do: {:reply, :ok}

  defcb sip_notify(_req, _call), do: {:reply, :ok}

  defcb sip_unsolicited_notify(_req, _call), do: {:reply, :no_transaction}

  defcb sip_refer(_req, _call), do: {:reply, :decline}

  defcb sip_publish(_req, call), do: {:reply, {:method_not_allowed, call.config[:allow] || []}}

  defcb sip_info(_req, _call), do: {:reply, :ok}

  defcb sip_message(_req, _call), do: {:reply, :decline}

  defcb sip_prack(_req, _call), do: {:reply, :ok}

  @doc false
  # For plugins: a message just received, called in the transport process
  # before it reaches its call process. `:ok` processes it, `:drop`
  # discards it and `{:reply, sipreply}` answers a request statelessly.
  defcb caracola_received_message(_msg), do: :ok

  @doc false
  # For plugins: a request about to be sent through a port (its remote
  # address is the destination). `{:error, reason}` does not send it.
  defcb caracola_sending_request(_req, _port), do: :ok

  @doc false
  # For plugins: changes a new request received, before it is authorized and
  # routed. Each plugin returns {:cont, [req, call]} with its changes.
  defcb caracola_received_request(req, _call), do: req

  defcb sip_dialog_update(_event, _dialog, _call), do: :ok

  defcb sip_session_update(_event, _dialog, _call), do: :ok
end
