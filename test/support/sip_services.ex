defmodule Caracola.Test.Callbacks do
  @moduledoc false
  # Callbacks shared by the test services, driven by headers in the request
  # (as NkSIP's test callbacks):
  #
  #   * x-op: reply-stateless | reply-stateful | reply-invalid (in sip_route),
  #     busy | ok | answer | increment | decline | notfound | redirect (in
  #     sip_invite and sip_update). Without x-op, the user of the
  #     Request-URI is used.
  #   * x-redirect: Contact of the redirect
  #   * x-op in SUBSCRIBE: expires-2 (reply with Expires: 2) | wait (reply after 1s)
  #   * x-op in an unsolicited NOTIFY: ok (accept it)
  #   * x-prov: send 180 before the final response
  #   * x-sleep: milliseconds to wait (in another process) before replying
  #   * x-contact: Contact of the response
  #
  # `answer` replies with a new SDP, and `increment` with the local SDP of
  # the dialog with a new version.
  #
  # Received requests and dialog and session updates are sent to the
  # `test_pid` of the service config.
  #
  # Services with `proxy: [stateless: boolean, opts: list]` in their config
  # proxy the requests for the users in Caracola.Test.Location (and
  # in-dialog requests to their Request-URI), adding the proxy options in
  # the x-proxy-opts header (a base64 encoded term). Requests without user
  # are processed.
  #
  # Services with `auth: [realm: realm, dialog: boolean, proxy: boolean]`
  # require digest authentication (unless the request comes from an
  # authorized origin of its dialog, with `dialog: true`), and take the
  # passwords from `passwords: %{user => password}`.

  alias Caracola.{Message, SDP}
  alias Caracola.Test.Location

  defmacro __using__(_) do
    quote do
      alias Caracola.Message
      import Caracola.Test.Callbacks

      defcb sip_route(_scheme, user, _domain, req, call) do
        notify(call, {:route, Message.method(req)})

        case op(req) do
          "reply-stateless" -> {:reply_stateless, :ok}
          "reply-stateful" -> {:reply, :ok}
          "reply-invalid" -> {:reply, :not_a_reply}
          _ -> proxy_route(user, req, call)
        end
      end

      defcb sip_authorize(auth, _req, call) do
        case config(call, :auth) do
          nil -> :cont
          opts -> authorize(auth, opts)
        end
      end

      defcb sip_get_user_pass(user, _realm, _req, call) do
        case config(call, :passwords) do
          nil -> :cont
          passwords -> Map.get(passwords, user, false)
        end
      end

      defcb sip_options(req, call) do
        notify(call, {:options, req})
        maybe_async(req, call, {:ok, [:allow]})
      end

      defcb sip_invite(req, call) do
        case op(req) do
          "busy" -> maybe_async(req, call, :busy)
          "ok" -> maybe_async(req, call, {:ok, reply_opts(req, nil)})
          "answer" -> maybe_async(req, call, {:ok, reply_opts(req, answer(call))})
          "increment" -> maybe_async(req, call, {:ok, reply_opts(req, increment(req, call))})
          "decline" -> maybe_async(req, call, :decline)
          "notfound" -> maybe_async(req, call, :not_found)
          "redirect" -> maybe_async(req, call, {:redirect_temporary, header(req, "x-redirect")})
          "prov-busy" -> provisional(req, call, :ringing, :session_progress, :busy)
          "rel-prov-busy" -> provisional(req, call, :rel_ringing, :rel_session_progress, :busy)
          "pending" -> pending(req, call)
          "rel-ringing" -> maybe_async(req, call, :rel_ringing)
          "rel-prov-answer" <> _ = op -> rel_answer(op, req, call)
          _ -> :cont
        end
      end

      defcb sip_update(req, call) do
        case op(req) do
          "increment" -> {:reply, {:ok, reply_opts(req, increment(req, call))}}
          _ -> {:reply, {:ok, reply_opts(req, nil)}}
        end
      end

      defcb sip_dialog_update(event, _dialog, call) do
        notify(call, {:dialog, event})
        :ok
      end

      defcb sip_session_update(event, _dialog, call) do
        notify(call, {:session, event})
        :ok
      end

      defcb sip_info(req, call) do
        notify(call, {:info, req})
        :cont
      end

      defcb sip_bye(req, call) do
        notify(call, {:bye, req})
        :cont
      end

      defcb sip_subscribe(req, call) do
        notify(call, {:subscribe, req})

        case header(req, "x-op") do
          "expires-2" ->
            {:reply, {:ok, [expires: 2]}}

          "wait" ->
            spawn(fn ->
              Process.sleep(1000)
              Caracola.reply(req, :ok)
            end)

            :noreply

          _ ->
            {:reply, :ok}
        end
      end

      defcb sip_notify(req, call) do
        notify(call, {:notify, req.body})
        {:reply, :ok}
      end

      # Accepted with x-op: ok
      defcb sip_unsolicited_notify(req, call) do
        notify(call, {:unsolicited_notify, req.body})
        if op(req) == "ok", do: {:reply, :ok}, else: :cont
      end

      defcb sip_prack(req, call) do
        [rack] = Message.header(req, "rack")
        notify(call, {:prack, rack})

        case SDP.from_message(req) do
          nil -> {:reply, :ok}
          sdp -> {:reply, {:answer, %{sdp | address: {"IN", "IP4", inspect(call.service)}}}}
        end
      end

      defcb sip_message(req, call) do
        notify(call, {:message, req})
        {:reply, :ok}
      end

      defcb sip_cancel(inv_req, _cancel, call) do
        notify(call, {:cancel, inv_req.call_id})
        :ok
      end
    end
  end

  def op(req), do: header(req, "x-op") || req.ruri.user

  def ruri_param(req, name) do
    case Caracola.URI.get_param(req.ruri, name) do
      {:ok, value} when is_binary(value) -> value
      _ -> nil
    end
  end

  # Replies with two provisional responses (100ms between them) and a final one
  def provisional(req, _call, prov1, prov2, final) do
    spawn(fn ->
      :ok = Caracola.reply(req, prov1)
      Process.sleep(100)
      :ok = Caracola.reply(req, prov2)
      Process.sleep(100)
      Caracola.reply(req, final)
    end)

    :noreply
  end

  # A second reliable response before the PRACK of the first one
  def pending(req, call) do
    spawn(fn ->
      :ok = Caracola.reply(req, :rel_ringing)
      {:error, :pending_prack} = Caracola.reply(req, :rel_session_progress)
      notify(call, :pending_prack_ok)
      Process.sleep(100)
      Caracola.reply(req, :busy)
    end)

    :noreply
  end

  # Offer/answer with reliable provisional responses:
  #   * rel-prov-answer: answer in 180, 183 and 200 (with new versions)
  #   * rel-prov-answer2: answer in 180, 200 without SDP
  #   * rel-prov-answer3: offer in 180 (to be answered in the PRACK)
  #   * rel-prov-answer-wait: as rel-prov-answer2, with the 200 after 1s
  def rel_answer(op, req, call) do
    sdp =
      case {op, SDP.from_message(req)} do
        {"rel-prov-answer3", _} -> answer(call)
        {_, nil} -> nil
        {_, sdp} -> %{sdp | address: {"IN", "IP4", inspect(call.service)}}
      end

    spawn(fn ->
      :ok = Caracola.reply(req, {:rel_ringing, sdp})
      Process.sleep(100)

      if op == "rel-prov-answer-wait", do: Process.sleep(900)

      if op == "rel-prov-answer" do
        :ok = Caracola.reply(req, {:rel_session_progress, SDP.increment(sdp)})
        Process.sleep(100)
        Caracola.reply(req, {:answer, SDP.increment(SDP.increment(sdp))})
      else
        Caracola.reply(req, :ok)
      end
    end)

    :noreply
  end

  def config(call, key), do: call.service.get_config()[key]

  # See the module comment
  def proxy_route(user, req, call) do
    case config(call, :proxy) do
      nil ->
        :cont

      proxy ->
        mode = if proxy[:stateless], do: :proxy_stateless, else: :proxy
        opts = Keyword.get(proxy, :opts, []) ++ proxy_opts(req)

        cond do
          req.to_tag != nil -> {mode, :ruri, opts}
          user == nil -> :process
          uris = locate(call.service, proxy, user, req) -> {mode, uris, opts}
          ip?(req.ruri.domain) -> {mode, :ruri, opts}
          true -> {:reply, :temporarily_unavailable}
        end
    end
  end

  defp ip?(domain), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(domain)))

  # From the registrar, with `registrar: true`
  defp locate(service, proxy, user, req) do
    if proxy[:registrar] do
      %{scheme: scheme, domain: domain} = req.ruri

      case Caracola.Registrar.qfind(service, scheme, user, domain) do
        [] -> nil
        uri_set -> uri_set
      end
    else
      Location.find(service, user)
    end
  end

  defp proxy_opts(req) do
    case header(req, "x-proxy-opts") do
      nil -> []
      opts -> opts |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    end
  end

  def authorize(auth, opts) do
    digest = List.keyfind(auth, {:digest, opts[:realm]}, 0)

    cond do
      opts[:dialog] && :dialog in auth -> :ok
      opts[:register] && :register in auth -> :ok
      match?({_, true}, digest) -> :ok
      match?({_, false}, digest) -> :forbidden
      opts[:proxy] -> {:proxy_authenticate, opts[:realm]}
      true -> {:authenticate, opts[:realm]}
    end
  end

  def answer(call),
    do: SDP.new(inspect(call.service), [{"test", 4321, [{:rtpmap, 0, "codec1"}]}])

  def increment(req, call) do
    %{invite: %{local_sdp: sdp}} = Map.fetch!(call.dialogs, req.dialog_id)
    SDP.increment(sdp)
  end

  def reply_opts(req, body) do
    body = if body, do: [body: body], else: []

    case header(req, "x-contact") do
      nil -> body
      contact -> [{:contact, contact} | body]
    end
  end

  def header(req, name) do
    case Message.header(req, name) do
      [value] -> value
      _ -> nil
    end
  end

  def notify(call, msg) do
    case call.service.get_config()[:test_pid] do
      pid when is_pid(pid) -> send(pid, {call.service, msg})
      _ -> :ok
    end
  end

  # Replies at once, or from another process after x-prov and x-sleep
  def maybe_async(req, _call, reply) do
    prov? = header(req, "x-prov") != nil
    sleep = header(req, "x-sleep") || ruri_param(req, "sleep")

    if prov? or sleep do
      spawn(fn -> reply_later(req, reply, prov?, sleep) end)
      :noreply
    else
      {:reply, reply}
    end
  end

  defp reply_later(req, reply, prov?, sleep) do
    if prov?, do: Caracola.reply(req, :ringing)
    if sleep, do: Process.sleep(String.to_integer(sleep))
    Caracola.reply(req, reply)
  end
end

defmodule Caracola.Test.Location do
  @moduledoc false
  # Locations of users for the test proxies

  def put(service, user, uri_set), do: :persistent_term.put({__MODULE__, service, user}, uri_set)
  def find(service, user), do: :persistent_term.get({__MODULE__, service, user}, nil)
  def delete(service, user), do: :persistent_term.erase({__MODULE__, service, user})
end

defmodule Caracola.Test.Proxy do
  @moduledoc false
  use Malla.Service, plugins: [Caracola], sip: [listen: "sip:127.0.0.1:0"]
  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.Proxy2 do
  @moduledoc false
  use Malla.Service, plugins: [Caracola], sip: [listen: "sip:127.0.0.1:0"]
  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.Server do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola],
    sip: [listen: "sip:127.0.0.1:0", supported: "a, 100rel, path"]

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.Client do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola],
    sip: [listen: "sip:127.0.0.1:0", from: "\"Test Client\" <sip:client@caracola>"]

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.Server2 do
  @moduledoc false
  use Malla.Service, plugins: [Caracola], sip: [listen: "sip:127.0.0.1:0"]
  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.Registrar do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.Registrar],
    sip: [listen: "sip:127.0.0.1:0"]

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.Rel1 do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.Rel100],
    sip: [listen: "sip:127.0.0.1:0", no_100: true, timer_t1: 100, from: "<sip:rel1@caracola>"]

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.Rel2 do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.Rel100],
    sip: [listen: "sip:127.0.0.1:0", no_100: true, timer_t1: 100]

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.TimerUA1 do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.SessionTimers],
    sip: [listen: "sip:127.0.0.1:0", min_se: 1, from: "<sip:timer1@caracola>"]

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.TimerUA2 do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.SessionTimers],
    sip: [listen: "sip:127.0.0.1:0", min_se: 2]

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.TimerProxy do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.SessionTimers],
    sip: [listen: "sip:127.0.0.1:0", min_se: 3],
    proxy: []

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.ReferCallbacks do
  @moduledoc false
  # REFER callbacks: referred requests are accepted, and the updates of
  # REFER subscriptions are sent to the test process

  defmacro __using__(_) do
    quote do
      alias Caracola.Test.Callbacks

      defcb sip_refer(_refer_to, _req, _call), do: true

      defcb sip_refer_update(subs, status, call) do
        Callbacks.notify(call, {:refer, subs, status})
        :ok
      end
    end
  end
end

for {name, from} <- [Refer1: "refer1", Refer2: "refer2", Refer3: "refer3"] do
  defmodule Module.concat(Caracola.Test, name) do
    @moduledoc false
    use Malla.Service,
      plugins: [Caracola.Refer],
      sip: [listen: "sip:127.0.0.1:0", from: "<sip:#{from}@caracola>"]

    use Caracola.Test.Callbacks
    use Caracola.Test.ReferCallbacks
  end
end

defmodule Caracola.Test.Compositor do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.EventCompositor],
    sip: [listen: "sip:127.0.0.1:0", events: "nkpublish"]

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.AutoUA do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.UACAutoRegister],
    sip: [listen: "sip:127.0.0.1:0", from: "<sip:auto@caracola>"],
    uac_auto_register: [timer: 1]

  use Caracola.Test.Callbacks

  defcb sip_uac_auto_register_updated_reg(id, ok, service) do
    send(service.get_config()[:test_pid], {:reg, id, ok})
    :ok
  end

  defcb sip_uac_auto_register_updated_ping(id, ok, service) do
    send(service.get_config()[:test_pid], {:ping, id, ok})
    :ok
  end
end

for {name, plugins, config} <- [
      {ObRegistrar, [Caracola.Registrar, Caracola.Outbound], [proxy: []]},
      {ObUA1, [Caracola.Outbound], [sip: [from: "<sip:ob_ua1@caracola>"]]},
      {ObUA2, [Caracola.Outbound], [sip: [from: "<sip:ob_ua2@caracola>"]]},
      {ObEdge, [Caracola.Outbound], [proxy: [opts: [:path, :record_route]]]}
    ] do
  defmodule Module.concat(Caracola.Test, name) do
    @moduledoc false
    use Malla.Service,
        [plugins: plugins, sip: [listen: "sip:127.0.0.1:0"] ++ (config[:sip] || [])] ++
          Keyword.delete(config, :sip)

    use Caracola.Test.Callbacks
  end
end

for {name, plugins} <- [
      GruuRegistrar: [Caracola.Registrar, Caracola.Gruu],
      GruuUA1: [Caracola.Gruu],
      GruuUA2: [Caracola.Gruu]
    ] do
  defmodule Module.concat(Caracola.Test, name) do
    @moduledoc false
    use Malla.Service,
      plugins: plugins,
      sip: [listen: "sip:127.0.0.1:0", from: "<sip:client1@caracola>"]

    use Caracola.Test.Callbacks
  end
end

defmodule Caracola.Test.ObUA3 do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola.UACAutoOutbound],
    sip: [listen: "sip:127.0.0.1:0", from: "<sip:ob_ua3@caracola>"],
    uac_auto_register: [timer: 1],
    uac_auto_outbound: [all_fail: 1, any_ok: 2]

  use Caracola.Test.Callbacks
end

for {name, from} <- [Repl1: "repl1", Repl2: "repl2", Repl3: "repl3"] do
  defmodule Module.concat(Caracola.Test, name) do
    @moduledoc false
    use Malla.Service,
      plugins: [Caracola.Replaces, Caracola.Join, Caracola.Refer],
      sip: [listen: "sip:127.0.0.1:0", from: "<sip:#{from}@caracola>"]

    use Caracola.Test.Callbacks
    use Caracola.Test.ReferCallbacks
  end
end

defmodule Caracola.Test.AiProxy do
  @moduledoc false
  # Proxy with Caracola.AssertedIdentity (see Caracola.Test.Callbacks)
  use Malla.Service,
    plugins: [Caracola.AssertedIdentity],
    sip: [listen: "sip:127.0.0.1:0"],
    proxy: []

  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.AiUAS do
  @moduledoc false
  # Answers INVITEs, sending the identities they have to the test_pid
  use Malla.Service, plugins: [Caracola.AssertedIdentity], sip: [listen: "sip:127.0.0.1:0"]

  alias Caracola.{AssertedIdentity, Message}

  defcb sip_invite(req, call) do
    identities = for uri <- AssertedIdentity.identities(req), do: "#{uri.user}@#{uri.domain}"
    preferred = Message.header(req, "p-preferred-identity")
    send(call.service.get_config()[:test_pid], {:identity, identities, preferred})
    {:reply, :ok}
  end
end

defmodule Caracola.Test.PresServer do
  @moduledoc false
  # Presence and dialog state server. Subscriptions from eve are rejected.
  use Malla.Service,
    plugins: [
      Caracola.Presence,
      Caracola.DialogInfo,
      Caracola.MessageWaiting,
      Caracola.Conference
    ],
    sip: [listen: "sip:127.0.0.1:0"]

  use Caracola.Test.Callbacks

  defcb sip_notifier_authorize(_event, _aor, req, _call),
    do: if(req.from.user == "eve", do: :forbidden, else: :cont)
end

defmodule Caracola.Test.RlServer do
  @moduledoc false
  # Server with Caracola.RateLimit (see Caracola.Test.Callbacks)
  use Malla.Service, plugins: [Caracola.RateLimit], sip: [listen: "sip:127.0.0.1:0"]
  use Caracola.Test.Callbacks
end

defmodule Caracola.Test.DsProxy do
  @moduledoc false
  # Proxy sending every request to the :gws group of Caracola.Dispatcher
  use Malla.Service, plugins: [Caracola.Dispatcher], sip: [listen: "sip:127.0.0.1:0"]

  defcb sip_route(_scheme, _user, _domain, req, call),
    do: Caracola.Dispatcher.route(:gws, req, call)
end

for name <- [ShakenUA1, ShakenUA2] do
  defmodule Module.concat(Caracola.Test, name) do
    @moduledoc false
    # Caracola.StirShaken user agents. Certificates are fetched from the
    # `certs: %{url => pem}` of the config (each fetch is sent to the
    # test_pid), and INVITEs are answered sending the verification result.
    use Malla.Service, plugins: [Caracola.StirShaken], sip: [listen: "sip:127.0.0.1:0"]

    defcb sip_stir_shaken_fetch(url, service) do
      config = service.get_config()
      send(config[:test_pid], {:fetch, url})

      case Map.fetch(config[:certs] || %{}, url) do
        {:ok, pem} -> {:ok, pem}
        :error -> {:error, :not_found}
      end
    end

    defcb sip_invite(req, call) do
      send(
        call.service.get_config()[:test_pid],
        {:verify, Caracola.StirShaken.verify(call.service, req)}
      )

      {:reply, :ok}
    end
  end
end

defmodule Caracola.Test.PushProxy do
  @moduledoc false
  # Registrar and proxy with Caracola.Push. Push notifications are sent to
  # the test_pid, and succeed unless `push_result` is set in the config.
  use Malla.Service, plugins: [Caracola.Push], sip: [listen: "sip:127.0.0.1:0"]

  defcb sip_route(_scheme, _user, _domain, req, call) do
    case req do
      %{class: {:req, :register}} -> :process
      %{to_tag: tag} when tag != nil -> :proxy
      _ -> Caracola.Push.route(req, call)
    end
  end

  defcb sip_push_send(push, _req, service) do
    config = service.get_config()
    send(config[:test_pid], {:push, push})
    config[:push_result] || :ok
  end
end

defmodule Caracola.Test.ClusterReg do
  @moduledoc false
  # Registrar shared among the nodes of a cluster
  use Malla.Service,
    global: true,
    plugins: [Caracola.Registrar.Cluster],
    sip: [listen: "sip:127.0.0.1:0"]
end

defmodule Caracola.Test.Cluster do
  @moduledoc false
  # Peer nodes for the cluster tests (needs distribution: epmd must be
  # running, as with `epmd -daemon`)

  # Starts a peer node with the code of this one, and Caracola
  def start_peer(name) do
    if not Node.alive?() do
      {:ok, _} = Node.start(:"caracola_main@127.0.0.1", name_domain: :longnames)
      Node.set_cookie(:caracola_test)
    end

    args = [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
    args = args ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, node} =
      :peer.start_link(%{name: name, host: ~c"127.0.0.1", longnames: true, args: args})

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:caracola])
    :ok = :erpc.call(node, Logger, :configure, [[level: :warning]])
    {peer, node}
  end

  # Starts a service in a node, not linked to the caller
  def start_service(node, service, config \\ []) do
    :erpc.call(node, __MODULE__, :start_local, [service, config])
  end

  def start_local(service, config) do
    {:ok, pid} = service.start_link(config)
    Process.unlink(pid)
    wait(fn -> Malla.Service.is_ready?(service) and length(Caracola.listeners(service)) >= 2 end)
    [%{local_port: port} | _] = Caracola.listeners(service)
    port
  end

  def wait(fun, retries \\ 200) do
    cond do
      fun.() ->
        :ok

      retries == 0 ->
        raise "condition not met"

      true ->
        Process.sleep(25)
        wait(fun, retries - 1)
    end
  end
end

for name <- [OcServer, OcClient] do
  defmodule Module.concat(Caracola.Test, name) do
    @moduledoc false
    # Services with Caracola.OverloadControl (see Caracola.Test.Callbacks)
    use Malla.Service, plugins: [Caracola.OverloadControl], sip: [listen: "sip:127.0.0.1:0"]
    use Caracola.Test.Callbacks
  end
end

defmodule Caracola.Test.B2B do
  @moduledoc false
  # Bridges the INVITEs to the same user at the service in the config
  # `target`, sending the bridge events to the test_pid. The `sdp` config
  # changes the session name of the SDPs relayed
  use Malla.Service,
    plugins: [Caracola.B2BUA],
    sip: [listen: "sip:127.0.0.1:0", from: "<sip:b2b@caracola>"]

  alias Caracola.Test.Helpers

  defcb sip_invite(req, call) do
    config = call.service.get_config()
    uri = %{req.ruri | domain: "127.0.0.1", port: Helpers.port(config[:target])}
    Caracola.B2BUA.bridge(req, uri, copy_headers: ["x-prov", "x-sleep", "x-copied"], meta: :test)
  end

  defcb sip_b2bua_sdp(sdp, from, bridge) do
    case bridge.service.get_config()[:sdp] do
      nil -> sdp
      name -> %{sdp | session: "#{name} #{from}"}
    end
  end

  defcb sip_b2bua_update(event, bridge) do
    send(bridge.service.get_config()[:test_pid], {:b2bua, event, bridge})
    :ok
  end
end

for name <- [HistProxy1, HistProxy2] do
  defmodule Module.concat(Caracola.Test, name) do
    @moduledoc false
    # Forward alice to bob (at HistProxy2) and bob to the voicemail at HistUAS
    use Malla.Service, plugins: [Caracola], sip: [listen: "sip:127.0.0.1:0"]

    alias Caracola.History
    alias Caracola.Test.Helpers

    defcb sip_route(_scheme, "alice", _domain, req, _call) do
      bob = "sip:bob@127.0.0.1:#{Helpers.port(Caracola.Test.HistProxy2)}"
      History.retarget(req, [bob], cause: 302)
    end

    defcb sip_route(_scheme, "bob", _domain, req, _call) do
      uas = "sip:vm@127.0.0.1:#{Helpers.port(Caracola.Test.HistUAS)}"
      History.retarget(req, [uas], [:diversion, cause: 486, type: :rc])
    end
  end
end

defmodule Caracola.Test.HistUAS do
  @moduledoc false
  # Sends the INVITEs to the test_pid
  use Malla.Service, plugins: [Caracola], sip: [listen: "sip:127.0.0.1:0"]

  defcb sip_invite(req, call) do
    send(call.service.get_config()[:test_pid], {:invite, req})
    {:reply, :ok}
  end
end

defmodule Caracola.Test.WinfoServer do
  @moduledoc false
  # Message waiting with watcher information: watchers other than
  # "friend" are pending
  use Malla.Service,
    plugins: [Caracola.MessageWaiting, Caracola.WatcherInfo],
    sip: [listen: "sip:127.0.0.1:0"],
    watcher_info: [events: ["message-summary"]]

  defcb sip_notifier_authorize("message-summary", _aor, req, _call),
    do: if(req.from.user == "friend", do: :ok, else: :pending)

  defcb sip_notifier_authorize(_event, _aor, _req, _call), do: :cont
end

for {name, packages} <- [InfoUA1: ["dtmf"], InfoUA2: ["dtmf", "Foo"]] do
  defmodule Module.concat(Caracola.Test, name) do
    @moduledoc false
    use Malla.Service,
      plugins: [Caracola.InfoPackages],
      sip: [listen: "sip:127.0.0.1:0"],
      info_packages: packages

    use Caracola.Test.Callbacks
  end
end

defmodule Caracola.Test.HepUA do
  @moduledoc false
  # Captured with HEP (to the hep config given by the test)
  use Malla.Service, plugins: [Caracola.HEP], sip: [listen: "sip:127.0.0.1:0"]

  defcb sip_options(_req, _call), do: {:reply, :ok}
end

defmodule Caracola.Test.SRS do
  @moduledoc false
  # Session recording server: sends the recording sessions to the test_pid
  use Malla.Service, plugins: [Caracola.Siprec], sip: [listen: "sip:127.0.0.1:0"]

  alias Caracola.{SDP, Siprec}

  defcb sip_invite(req, call) do
    if Siprec.recording_session?(req) do
      {:ok, rec} = Siprec.decode(req)
      send(call.service.get_config()[:test_pid], {:recording, req, rec})
      answer = SDP.new("srs", for(m <- rec.sdp.medias, do: {m.media, 4000, []}))
      {:reply, {:ok, body: SDP.update(answer, :recvonly)}}
    else
      {:reply, :forbidden}
    end
  end
end
