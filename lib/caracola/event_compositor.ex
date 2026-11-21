defmodule Caracola.EventCompositor do
  @moduledoc """
  Event state compositor for PUBLISH (RFC 3903). Equivalent to NkSIP's
  `nksip_event_compositor`.

  ```
  defmodule MyCompositor do
    use Malla.Service,
      plugins: [Caracola.EventCompositor],
      sip: [listen: "sip:all:5060", events: "presence"],
      event_compositor: [default_expires: 60]
  end
  ```

  It answers PUBLISH requests (`sip_publish/2`, see `request/1`) for the
  events of the service (`:events` of the sip config), and adds `PUBLISH`
  to the Allow header. Each publication is stored for the AOR of the
  Request-URI with a new entity tag, returned in the SIP-ETag header (and
  the `:sip_etag` meta of `Caracola.UAC.publish/3`). PUBLISH requests with
  `{:sip_if_match, etag}` refresh (without body), modify (with body) or
  remove (with `expires: 0`) it; unknown tags get a 412.

  Publications are found with `find/3`, and all the current ones of an AOR
  and event with `list/3` (as `Caracola.Presence` does to compose the
  presence state).

  ## Configuration

  Under the `:event_compositor` key:

    * `:default_expires` - expiration without Expires (secs, default 60).

  ## Storage

  Publications are stored in memory. Services can use their own storage
  implementing `sip_event_compositor_store(op, service)`, where `op` is
  `{:get, aor, tag}` (returns a `Caracola.EventCompositor.Publication` or
  `:not_found`), `{:list, aor}` (returns `[{tag, publication}]`, without
  the expired ones), `{:put, aor, tag, publication, ttl}`, `{:del, aor, tag}`
  or `:del_all` (these return `:ok`).
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.EventCompositor.{Publication, Store}
  alias Caracola.{Message, Util}

  @schema NimbleOptions.new!(
            default_expires: [type: :pos_integer, default: 60, doc: "Default expiration (secs)."]
          )

  @typedoc "An address of record: scheme, user and domain."
  @type aor :: {Caracola.URI.scheme(), String.t() | nil, String.t()}

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc "Finds a publication by its AOR and entity tag."
  @spec find(module(), aor(), String.t()) :: {:ok, Publication.t()} | :not_found
  def find(service, aor, tag) do
    case store(service, {:get, aor, tag}) do
      %Publication{} = pub -> {:ok, pub}
      _ -> :not_found
    end
  end

  @doc """
  The current publications of an AOR for an event (as `"presence"`), as
  `{tag, publication}`, the oldest first.
  """
  @spec list(module(), aor(), String.t()) :: [{String.t(), Publication.t()}]
  def list(service, aor, event) do
    event = Util.ascii_downcase(event)

    service
    |> store({:list, aor})
    |> Enum.filter(fn {_tag, pub} -> pub.event == event end)
    |> Enum.sort_by(fn {_tag, pub} -> pub.updated end)
  end

  @doc "Removes all the publications of a service."
  @spec clear(module()) :: :ok
  def clear(service), do: store(service, :del_all)

  @doc """
  Processes a PUBLISH request, returning the reply. Called by the default
  `sip_publish/2`.
  """
  @spec request(Message.t()) :: Caracola.Reply.sipreply()
  def request(%Message{class: {:req, :publish}, service: service, ruri: ruri} = req) do
    expires =
      case req.expires do
        expires when is_integer(expires) and expires > 0 -> expires
        _ -> config(service)[:default_expires] || 60
      end

    aor = {ruri.scheme, ruri.user, ruri.domain}

    case Message.header(req, "sip-if-match") do
      [] when req.body == "" -> {:invalid_request, "No Body"}
      [] -> put(req, aor, Util.uid(), expires, req.body)
      [tag] -> update(req, aor, tag, expires)
      _ -> :invalid_request
    end
  end

  # Refresh (without body), modification or removal (expires 0)
  defp update(%Message{service: service} = req, aor, tag, expires) do
    case find(service, aor, tag) do
      {:ok, _pub} when req.expires == 0 ->
        delete(service, aor, tag)

      {:ok, pub} when req.body == "" ->
        put(%{req | content_type: pub.content_type}, aor, tag, expires, pub.data)

      {:ok, _pub} ->
        put(req, aor, tag, expires, req.body)

      :not_found ->
        :conditional_request_failed
    end
  end

  defp put(%Message{service: service} = req, aor, tag, expires, data) do
    now = System.os_time(:second)

    pub = %Publication{
      data: data,
      expires: now + expires,
      updated: System.monotonic_time(),
      event: event_type(req),
      content_type: req.content_type
    }

    :ok = store(service, {:put, aor, tag, pub, expires})
    {:ok, [sip_etag: tag, expires: expires]}
  end

  defp delete(service, aor, tag) do
    :ok = store(service, {:del, aor, tag})
    {:ok, [sip_etag: tag, expires: 0]}
  end

  defp event_type(%Message{event: {type, _}}), do: Util.ascii_downcase(type)
  defp event_type(_req), do: nil

  defp store(service, op), do: service.sip_event_compositor_store(op, service)

  defp config(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> Keyword.get(config, :event_compositor, [])
      _ -> []
    end
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <-
           NimbleOptions.validate(Keyword.get(config, :event_compositor, []), @schema) do
      config = Caracola.Config.add_values(config, :allow, ["PUBLISH"])
      {:ok, Keyword.put(config, :event_compositor, opts)}
    end
  end

  defcb sip_publish(req, _call), do: {:reply, request(req)}

  defcb sip_event_compositor_store(op, service), do: Store.op(op, service)
end
