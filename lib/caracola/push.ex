defmodule Caracola.Push do
  @moduledoc """
  Push notifications for mobile clients (RFC 8599), on top of
  `Caracola.Registrar`: devices that cannot keep a connection open are
  woken up with a push notification (APNs, FCM...) when they have a
  request, and get it after they register again.

  ```
  defmodule MyProxy do
    use Malla.Service,
      plugins: [Caracola.Push],
      sip: [listen: "sip:all:5060"],
      push: [providers: ["apns", "fcm"], timeout: 10_000]

    defcb sip_route(_scheme, _user, "example.com", req, call),
      do: Caracola.Push.route(req, call, [:record_route])

    defcb sip_push_send(push, _req, _service) do
      MyApp.Apns.send(push.prid, push.param, push.purr)
    end
  end
  ```

  ## Registration

  Devices register Contacts with the `pn-provider`, `pn-prid` (the push
  token) and `pn-param` URI parameters. The registrar identifies them by
  their provider and token, instead of by address (which changes when the
  device wakes up), and answers with a `Feature-Caps` header with the
  `+sip.pns` (the provider) and `+sip.pnspurr` (an identifier of the
  registration) indicators. Providers not in `:providers` are rejected with
  555 (Push Notification Service Not Supported).

  ## Routing

  `route/3` routes a request to the registered contacts of its
  Request-URI. If some of them have push parameters, a push notification
  is sent to each of them (with `sip_push_send/3`, that the service
  implements to talk to the push services), and the request waits until
  they register again, or until the `:timeout`. Then it is proxied to the
  other contacts and to the refreshed ones; if there are none, it is
  answered with 480. The call process does not wait: the request is routed
  later (see `Caracola.route/2`), so it can be cancelled meanwhile.

  Sending the notifications is up to the service: Caracola does not talk
  to APNs or FCM. `sip_push_send/3` gets a map with the `:provider`,
  `:prid`, `:param`, `:purr`, the `:aor` and the registered `:contact`,
  and returns `:ok` or `{:error, reason}`.

  ## Configuration

  Under the `:push` key:

    * `:providers` - supported push providers (default `["apns", "fcm",
      "webpush"]`).
    * `:timeout` - milliseconds to wait for the devices to register again
      (default 10000).
  """

  use Malla.Plugin, plugin_deps: [Caracola.Registrar]

  require Logger

  alias Caracola.{Message, Registrar, URI, Util}
  alias Caracola.Registrar.Contact

  @registry Caracola.Push.Registry

  @schema NimbleOptions.new!(
            providers: [type: {:list, :string}, default: ["apns", "fcm", "webpush"]],
            timeout: [type: :pos_integer, default: 10_000]
          )

  @typedoc "The push parameters (RFC 8599) of a registered contact: provider, token (`prid`), `purr`, AOR and contact."
  @type push :: %{
          provider: String.t(),
          prid: String.t(),
          param: String.t() | nil,
          purr: String.t(),
          aor: Registrar.aor(),
          contact: URI.t()
        }

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  A `sip_route/5` result for a request to a registered user: the
  contacts registered for its Request-URI, after waking up the devices
  with push notifications (see the module documentation). `proxy_opts` are
  the options for proxying.
  """
  @spec route(Message.t(), Caracola.Call.t(), list()) :: term()
  def route(%Message{ruri: ruri} = req, call, proxy_opts \\ []) do
    service = call.service
    aor = {ruri.scheme, ruri.user, ruri.domain}
    regs = Registrar.get_info(service, aor)
    {pushes, others} = Enum.split_with(regs, &(push(&1.contact, aor) != nil))

    cond do
      regs == [] -> {:reply, :temporarily_unavailable}
      pushes == [] -> {:proxy, uri_set(others), proxy_opts}
      true -> wake_up(req, service, aor, pushes, proxy_opts)
    end
  end

  @doc """
  The push parameters of a Contact (RFC 8599 §4.1), or `nil` if it has
  none.

      iex> {:ok, uri} = Caracola.URI.parse_one("<sip:a@10.0.0.1;pn-provider=apns;pn-prid=tok;pn-param=t.app>")
      iex> push = Caracola.Push.push(uri, {:sip, "a", "example.com"})
      iex> {push.provider, push.prid, push.param}
      {"apns", "tok", "t.app"}
  """
  @spec push(URI.t(), Registrar.aor()) :: push() | nil
  def push(%URI{} = contact, aor) do
    with {:ok, provider} when is_binary(provider) <- URI.get_param(contact, "pn-provider"),
         {:ok, prid} when is_binary(prid) <- URI.get_param(contact, "pn-prid") do
      provider = Util.ascii_downcase(provider)

      param =
        case URI.get_param(contact, "pn-param") do
          {:ok, param} when is_binary(param) -> param
          _ -> nil
        end

      %{
        provider: provider,
        prid: prid,
        param: param,
        purr: purr(provider, prid),
        aor: aor,
        contact: contact
      }
    else
      _ -> nil
    end
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <- NimbleOptions.validate(Keyword.get(config, :push, []), @schema) do
      providers = Enum.map(opts[:providers], &Util.ascii_downcase/1)
      {:ok, Keyword.put(config, :push, Keyword.put(opts, :providers, providers))}
    end
  end

  @doc false
  # Sends a push notification, returning :ok or {:error, reason}
  defcb sip_push_send(_push, _req, service) do
    Logger.warning("sip_push_send/3 is not implemented by #{inspect(service)}")
    {:error, :not_implemented}
  end

  defcb sip_register(%Message{to: to} = req, call) do
    aor = {to.scheme, to.user, to.domain}
    pushes = for contact <- req.contacts, push = push(contact, aor), push != nil, do: push
    providers = config(call.service)[:providers]

    case Enum.find(pushes, &(&1.provider not in providers)) do
      nil -> {:reply, register(req, pushes, call.service)}
      _ -> {:reply, {555, reason_phrase: "Push Notification Service Not Supported"}}
    end
  end

  defp register(req, pushes, service) do
    case Registrar.request(req) do
      {:ok, opts} when pushes != [] ->
        # The routes waiting for these devices go on
        for push <- pushes, do: registered(service, push.purr)

        [push | _] = pushes
        caps = ~s(*;+sip.pns="#{push.provider}";+sip.pnspurr="#{push.purr}")
        {:ok, opts ++ [{:add, "feature-caps", caps}]}

      reply ->
        reply
    end
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp registered(service, purr) do
    Registry.dispatch(@registry, {service, purr}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:push_registered, purr})
    end)
  end

  defp config(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> Keyword.get(config, :push, [])
      _ -> []
    end
  end

  # An identifier of the registration of a device (RFC 8599 §4.1.2)
  defp purr(provider, prid), do: Util.hash({provider, prid})

  defp uri_set(regs) do
    regs
    |> Enum.sort_by(&{-&1.q, -&1.updated})
    |> Enum.chunk_by(& &1.q)
    |> Enum.map(fn regs -> Enum.map(regs, &Registrar.make_contact/1) end)
  end

  # From another process, the devices are sent a push notification, and
  # the request is routed when they have registered again
  defp wake_up(req, service, aor, pushes, proxy_opts) do
    timeout = config(service)[:timeout]

    {:ok, _} =
      Task.start(fn ->
        purrs =
          for %Contact{contact: contact} <- pushes,
              push = push(contact, aor),
              notify(service, push, req) == :ok,
              do: push.purr

        refreshed = wait(purrs, [], System.monotonic_time(:millisecond) + timeout)
        Caracola.route(req, routed(service, aor, refreshed, proxy_opts))
      end)

    :noreply
  end

  # Waits for the REGISTER before sending the push, not to miss it
  defp notify(service, push, req) do
    {:ok, _} = Registry.register(@registry, {service, push.purr}, nil)
    send_push(service, push, req)
  end

  defp send_push(service, push, req) do
    case service.sip_push_send(push, req, service) do
      :ok ->
        :ok

      other ->
        Logger.notice("push notification to #{push.provider} failed: #{inspect(other)}")
        :error
    end
  rescue
    error ->
      Logger.error("error sending a push notification: #{Exception.message(error)}")
      :error
  end

  defp wait([], refreshed, _deadline), do: refreshed

  defp wait(purrs, refreshed, deadline) do
    receive do
      {:push_registered, purr} ->
        if purr in purrs,
          do: wait(List.delete(purrs, purr), [purr | refreshed], deadline),
          else: wait(purrs, refreshed, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> refreshed
    end
  end

  # The contacts without push, and the ones with push that have registered
  # again
  defp routed(service, aor, refreshed, proxy_opts) do
    regs =
      Enum.filter(Registrar.get_info(service, aor), fn reg ->
        case push(reg.contact, aor) do
          nil -> true
          push -> push.purr in refreshed
        end
      end)

    case regs do
      [] -> {:reply, :temporarily_unavailable}
      _ -> {:proxy, uri_set(regs), proxy_opts}
    end
  end
end
