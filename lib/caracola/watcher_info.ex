defmodule Caracola.WatcherInfo do
  @moduledoc """
  Watcher information (RFC 3857, RFC 3858): the `.winfo` template event
  packages, with `application/watcherinfo+xml` bodies, that tell a
  presentity who is subscribed to its state, so it can authorize the
  pending watchers.

  ```
  defmodule MyPresence do
    use Malla.Service,
      plugins: [Caracola.Presence, Caracola.WatcherInfo],
      sip: [listen: "sip:all:5060"],
      watcher_info: [events: ["presence"]]

    # Unknown watchers wait until the presentity authorizes them
    defcb sip_notifier_authorize("presence", aor, req, _call),
      do: if(MyApp.allowed?(aor, req.from), do: :ok, else: :pending)

    defcb sip_notifier_authorize(_event, _aor, _req, _call), do: :cont
  end
  ```

  The plugin is built on `Caracola.Notifier`: for each event of `:events`
  it accepts SUBSCRIBEs to `<event>.winfo` (`presence.winfo`), and sends
  to them the watchers of the resource (see
  `Caracola.Notifier.watcher_info/3`) whenever they change. Only the
  resource itself can subscribe (the AOR of the From must be the one of
  the Request-URI); services can change it implementing
  `sip_notifier_authorize/4` for the `.winfo` events.

  Pending watchers (those `sip_notifier_authorize/4` answered with
  `:pending`) are authorized with `Caracola.Notifier.approve/1`, or
  rejected with `Caracola.Notifier.terminate/2`, by the application (for
  example, from the authorization rules of the presentity). Rejected
  watchers appear in one notification as terminated, and then are
  removed. Only full state is sent.

  ## Configuration

  Under the `:watcher_info` key:

    * `:events` - the event packages with watcher information (default
      `["presence"]`).
  """

  use Malla.Plugin, plugin_deps: [Caracola.Notifier]

  alias Caracola.{Notifier, Util, XML}

  @content_type "application/watcherinfo+xml"

  @schema NimbleOptions.new!(events: [type: {:list, :string}, default: ["presence"]])

  @statuses %{"active" => :active, "pending" => :pending, "waiting" => :waiting}

  @typedoc """
  A watcher of a watcherinfo document: its id, status (`:active`,
  `:pending`, `:waiting` or `:terminated`), the event that changed it
  (`"subscribe"`, `"approved"`, `"rejected"`, `"timeout"`...), the URI and
  the seconds it has been subscribed.
  """
  @type watcher :: %{
          id: String.t(),
          status: :active | :pending | :waiting | :terminated,
          event: String.t() | nil,
          uri: String.t(),
          duration: non_neg_integer() | nil
        }

  @typedoc "A list of watchers of a resource and package."
  @type list_info :: %{resource: String.t(), package: String.t(), watchers: [watcher()]}

  @typedoc "A watcherinfo document."
  @type document :: %{
          version: non_neg_integer() | nil,
          state: :full | :partial | nil,
          lists: [list_info()]
        }

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Encodes a watcherinfo document with the watchers of a resource (as
  returned by `Caracola.Notifier.watcher_info/3`).
  """
  @spec encode(String.t(), String.t(), non_neg_integer(), [Notifier.watcher()]) :: binary()
  def encode(resource, package, version, watchers) do
    now = System.os_time(:second)

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<watcherinfo xmlns="urn:ietf:params:xml:ns:watcherinfo" version="#{version}" ),
      ~s(state="full">\n),
      ~s(<watcher-list resource="#{XML.escape(resource)}" package="#{XML.escape(package)}">\n),
      Enum.map(watchers, &encode_watcher(&1, now)),
      "</watcher-list>\n</watcherinfo>\n"
    ])
  end

  defp encode_watcher(watcher, now) do
    {status, event} =
      case watcher.status do
        :active -> {"active", "approved"}
        :pending -> {"pending", "subscribe"}
        {:terminated, reason} -> {"terminated", Atom.to_string(reason || :rejected)}
      end

    id = Util.hash(watcher.handle)
    duration = max(now - watcher.since, 0)

    [
      ~s(<watcher id="#{id}" status="#{status}" event="#{event}" ),
      ~s(duration-subscribed="#{duration}">),
      XML.escape(watcher.uri),
      "</watcher>\n"
    ]
  end

  @doc "Parses a watcherinfo document."
  @spec decode(binary()) :: {:ok, document()} | :error
  def decode(body) do
    case XML.parse(body) do
      {:ok, {"watcherinfo", _, _} = root} ->
        {:ok,
         %{
           version: integer(XML.attr(root, "version")),
           state:
             case XML.attr(root, "state") do
               "full" -> :full
               "partial" -> :partial
               _ -> nil
             end,
           lists: Enum.map(XML.children(root, "watcher-list"), &decode_list/1)
         }}

      _ ->
        :error
    end
  end

  defp decode_list(list) do
    %{
      resource: XML.attr(list, "resource"),
      package: XML.attr(list, "package"),
      watchers:
        for watcher <- XML.children(list, "watcher") do
          %{
            id: XML.attr(watcher, "id"),
            status: Map.get(@statuses, XML.attr(watcher, "status"), :terminated),
            event: XML.attr(watcher, "event"),
            uri: XML.text(watcher),
            duration: integer(XML.attr(watcher, "duration-subscribed"))
          }
        end
    }
  end

  defp integer(nil), do: nil

  defp integer(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <- NimbleOptions.validate(Keyword.get(config, :watcher_info, []), @schema) do
      events = Enum.map(opts[:events], &Util.ascii_downcase/1)
      config = Notifier.add_events(config, Enum.map(events, &(&1 <> ".winfo")))
      {:ok, Keyword.put(config, :watcher_info, events: events)}
    end
  end

  defcb sip_notifier_authorize(event, aor, req, _call) do
    if String.ends_with?(event, ".winfo") do
      from = req.from

      if {from.scheme, from.user, Util.ascii_downcase(from.domain)} ==
           put_elem(aor, 2, Util.ascii_downcase(elem(aor, 2))),
         do: :ok,
         else: :forbidden
    else
      :cont
    end
  end

  defcb sip_notifier_body(event, aor, version, service) do
    case String.split(event, ".winfo") do
      [package, ""] ->
        watchers = Notifier.watcher_info(service, package, aor)
        {@content_type, encode(Notifier.uri(aor), package, version, watchers)}

      _ ->
        :cont
    end
  end
end
