defmodule Caracola.Notifier do
  @moduledoc """
  Notifier of event packages (RFC 6665 §4.2): accepts subscriptions to the
  state of a resource and sends NOTIFYs with it, initially and whenever it
  changes. It is the base of `Caracola.Presence`, `Caracola.DialogInfo`,
  `Caracola.MessageWaiting` and `Caracola.Conference`, and of any other
  event package with the state in a body.

  A plugin built on it adds its events with `add_events/2` in its
  `c:Malla.Plugin.plugin_config/2`, and implements
  `sip_notifier_body(event, aor, version, service)`, returning the
  current state as `{content_type, body}` (or `:none` for a NOTIFY without
  body). For example, a message waiting package taking the summaries from
  a voicemail system (`Caracola.MessageWaiting` keeps them itself):

  ```
  defmodule MyMWI do
    use Malla.Plugin, plugin_deps: [Caracola.Notifier]

    @impl true
    def plugin_config(_srv_id, config),
      do: {:ok, Caracola.Notifier.add_events(config, ["message-summary"])}

    defcb sip_notifier_body("message-summary", {_scheme, user, _domain}, _version, _service),
      do: {"application/simple-message-summary", MyVoicemail.summary(user)}

    defcb sip_notifier_body(_event, _aor, _version, _service), do: :cont
  end
  ```

  The resource of a SUBSCRIBE is the AOR (`{scheme, user, domain}`) of its
  Request-URI. Before accepting it, the plugin calls
  `sip_notifier_authorize(event, aor, req, call)`, which returns `:ok`
  (the default), `:pending` or a reply to reject it (as `:forbidden`).
  Accepted subscriptions get a 200 and a NOTIFY with the current state, and another
  one with each refresh; when the state of a resource changes, call
  `notify/3` to send it to all its watchers.

  Pending subscriptions get NOTIFYs with `Subscription-State: pending` and
  no state, until they are authorized with `approve/1` or rejected with
  `terminate/2`. `watcher_info/3` returns the watchers of a resource and
  their status, and `Caracola.WatcherInfo` sends them to the subscribers
  of the `.winfo` packages (RFC 3857).

  `version` starts at 0 and grows with each NOTIFY of a subscription (as
  RFC 4235 requires). The NOTIFYs of a resource are sent in order by the
  same process, so watchers get the states in the order they happened.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.{Message, Subscription, Util}
  alias Caracola.Notifier.{Store, Worker}

  @typedoc "A resource: the AOR of the Request-URI of the subscriptions."
  @type aor :: {Caracola.URI.scheme(), String.t() | nil, String.t()}

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Adds event packages to the notifier, and to the `:events` of the sip
  configuration. For plugins, in their `c:Malla.Plugin.plugin_config/2`.
  """
  @spec add_events(keyword(), [String.t()]) :: keyword()
  def add_events(config, events) do
    events = Enum.map(events, &Util.ascii_downcase/1)

    config
    |> Caracola.Config.add_values(:events, events)
    |> Keyword.update(:notifier, [events: events], fn opts ->
      Keyword.update(opts, :events, events, &Enum.uniq(&1 ++ events))
    end)
  end

  @doc """
  Sends the current state of a resource to all its watchers (in the
  background).

  With `{:then, fun}`, `fun` (without arguments) is called once the NOTIFYs
  have been queued, before any later state is read: for example, to forget
  ended items that must appear in one notification.
  """
  @spec notify(module(), String.t(), aor(), keyword()) :: :ok
  def notify(service, event, aor, opts \\ []),
    do: Worker.notify(service, Util.ascii_downcase(event), aor, :all, opts[:then])

  @doc """
  Stores an item of the state of a resource (`nil` removes it), for
  plugins that keep the state in the notifier. Items are kept in memory,
  in the node.
  """
  @spec put_item(module(), String.t(), aor(), term(), term()) :: :ok
  def put_item(service, event, aor, key, value),
    do: Store.put_item(service, Util.ascii_downcase(event), aor, key, value)

  @doc "The items of the state of a resource, as `{key, value}`, ordered by key."
  @spec items(module(), String.t(), aor()) :: [{term(), term()}]
  def items(service, event, aor), do: Store.items(service, Util.ascii_downcase(event), aor)

  @doc "The subscriptions to an event of a resource."
  @spec watchers(module(), String.t(), aor()) :: [Subscription.handle()]
  def watchers(service, event, aor), do: Store.watchers(service, Util.ascii_downcase(event), aor)

  @typedoc """
  A watcher of a resource: its subscription, status, the URI of the
  subscriber (its From) and when it subscribed (system time in seconds).
  """
  @type watcher :: %{
          handle: Subscription.handle(),
          status: :active | :pending | {:terminated, Subscription.reason()},
          uri: String.t(),
          since: integer()
        }

  @doc "The watchers of an event of a resource."
  @spec watcher_info(module(), String.t(), aor()) :: [watcher()]
  def watcher_info(service, event, aor) do
    for {handle, status, watcher} <- Store.info(service, Util.ascii_downcase(event), aor),
        do: Map.merge(watcher, %{handle: handle, status: status})
  end

  @doc """
  Authorizes a pending subscription: its watcher gets a NOTIFY with the
  current state.
  """
  @spec approve(Subscription.handle()) :: :ok | {:error, :not_found}
  def approve(handle) do
    with {service, event, aor} <- Store.lookup(handle),
         true <- Store.set_status(handle, :active) do
      Worker.notify(service, event, aor, [handle], nil)
      winfo_changed(service, event, aor)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Ends a subscription, with a last NOTIFY with the `reason` (`:rejected`
  by default, or `:deactivated`, `:probation`, `:timeout`, `:giveup` or
  `:noresource`).
  """
  @spec terminate(Subscription.handle(), Subscription.reason()) :: :ok | {:error, :not_found}
  def terminate(handle, reason \\ :rejected) do
    with {service, event, aor} <- Store.lookup(handle),
         true <- Store.set_status(handle, {:terminated, reason}) do
      # The watcher info shows it before it is removed
      winfo_changed(service, event, aor)
      Worker.notify(service, event, aor, [handle], fn -> removed(handle) end)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  # Removes a subscription, notifying the watcher info
  def removed(handle) do
    case Store.lookup(handle) do
      {service, event, aor} ->
        Store.remove(handle)
        winfo_changed(service, event, aor)

      nil ->
        :ok
    end
  end

  # The watchers of an event changed: the subscribers to its watcher info
  # are notified
  defp winfo_changed(service, event, aor) do
    winfo = event <> ".winfo"
    if winfo in events(service), do: notify(service, winfo, aor), else: :ok
  end

  @doc """
  The URI of a resource, as `"sip:alice@example.com"`.

      iex> Caracola.Notifier.uri({:sip, "alice", "example.com"})
      "sip:alice@example.com"
  """
  @spec uri(aor()) :: String.t()
  def uri({scheme, nil, domain}), do: "#{scheme}:#{domain}"
  def uri({scheme, user, domain}), do: "#{scheme}:#{user}@#{domain}"

  @doc "The resource of a request: the AOR of its Request-URI."
  @spec aor(Message.t()) :: aor()
  def aor(%Message{ruri: ruri}), do: {ruri.scheme, ruri.user, ruri.domain}

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config),
    do: {:ok, Keyword.update(config, :notifier, [events: []], &Keyword.put_new(&1, :events, []))}

  defcb sip_notifier_authorize(_event, _aor, _req, _call), do: :ok

  defcb sip_notifier_body(_event, _aor, _version, _service), do: :none

  defcb caracola_callback(:sip_subscribe, [req, call]) do
    with {:ok, event} <- event(req, call) do
      aor = aor(req)

      case call.service.sip_notifier_authorize(event, aor, req, call) do
        status when status in [:ok, :pending] ->
          # The NOTIFY gets to the call after the 200
          handle = Subscription.handle_of(req)
          status = if status == :ok, do: :active, else: :pending
          from = req.from

          watcher = %{
            uri: uri({from.scheme, from.user, from.domain}),
            since: System.os_time(:second)
          }

          Store.add(handle, call.service, event, aor, status, watcher)
          Worker.notify(call.service, event, aor, [handle], nil)
          winfo_changed(call.service, event, aor)
          {:done, {:reply, :ok}}

        reply ->
          {:done, {:reply, reply}}
      end
    end
  end

  # A refresh gets a NOTIFY (the last one if it has Expires: 0)
  def caracola_callback(:sip_resubscribe, [req, call]) do
    with {:ok, _event} <- event(req, call) do
      handle = Subscription.handle_of(req)

      case Store.lookup(handle) do
        {service, event, aor} -> Worker.notify(service, event, aor, [handle], nil)
        nil -> :ok
      end

      {:done, {:reply, :ok}}
    end
  end

  def caracola_callback(
        :sip_dialog_update,
        [{:subscription_status, status, %Subscription{class: :uas} = subs}, _dialog, _call]
      )
      when elem(status, 0) == :terminated do
    removed(Subscription.handle(subs))
    :cont
  end

  def caracola_callback(_fun, _args), do: :cont

  # The event type of a request, if it is one of the notifier
  defp event(%Message{event: {type, _}}, call) do
    type = Util.ascii_downcase(type)
    if type in events(call.service), do: {:ok, type}, else: :cont
  end

  defp event(_req, _call), do: :cont

  defp events(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> get_in(config, [:notifier, :events]) || []
      _ -> []
    end
  end
end
