defmodule Caracola.Presence do
  @moduledoc """
  Presence (RFC 3856) with PIDF documents (RFC 3863): a presence server
  that composes the state published by the user agents of each presentity
  and notifies it to its watchers.

  ```
  defmodule MyPresenceServer do
    use Malla.Service,
      plugins: [Caracola.Presence],
      sip: [listen: "sip:all:5060"]

    # Only users of the domain can watch
    defcb sip_notifier_authorize("presence", _aor, req, _call),
      do: if(req.from.domain == "example.com", do: :ok, else: :forbidden)
  end
  ```

  The plugin depends on `Caracola.EventCompositor`, which stores the
  PUBLISH requests of the `presence` event, and on `Caracola.Notifier`,
  which accepts the SUBSCRIBEs (see `sip_notifier_authorize/4` there) and
  sends the NOTIFYs. Each change of the publications of a presentity (the
  AOR of the Request-URI) is notified to all its watchers, with the
  composite state:

    * with one publication, its document as it was published;
    * with several, a document with the tuples and notes of all of them
      (the latest publication wins when two tuples have the same id;
      elements of other namespaces, as RPID ones, are not kept);
    * with none, a document with a single `closed` tuple.

  A service can build the state itself (from its registrar, for example)
  implementing `sip_notifier_body("presence", aor, version, service)`.

  User agents publish their state with a PIDF built by `encode/3`, and
  watchers read the NOTIFYs with `decode/1`:

  ```
  body = Caracola.Presence.encode("sip:alice@example.com", [%{id: "pc", status: :open, note: "Online"}])

  {:ok, 200, meta} =
    Caracola.UAC.publish(MyUA, "sip:alice@example.com",
      event: "presence",
      content_type: Caracola.Presence.content_type(),
      body: body,
      expires: 3600
    )
  ```
  """

  use Malla.Plugin, plugin_deps: [Caracola.Notifier, Caracola.EventCompositor]

  alias Caracola.{EventCompositor, Message, Notifier, Util, XML}

  @content_type "application/pidf+xml"

  @typedoc "The basic status of a PIDF tuple."
  @type status :: :open | :closed

  @typedoc """
  A PIDF tuple: a way to contact the presentity (`:id` and `:status` are
  required when encoding, the rest are optional).
  """
  @type tuple_info :: %{
          optional(:id) => String.t(),
          optional(:status) => status() | nil,
          optional(:contact) => String.t() | nil,
          optional(:priority) => String.t() | nil,
          optional(:note) => String.t() | nil,
          optional(:timestamp) => String.t() | nil
        }

  @typedoc "A decoded PIDF document."
  @type document :: %{entity: String.t() | nil, tuples: [tuple_info()], notes: [String.t()]}

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc "The content type of PIDF documents."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc """
  Builds a PIDF document. Options: `:notes` (a list of notes of the
  presentity).

      iex> Caracola.Presence.encode("sip:alice@example.com", [%{id: "a1", status: :open}])
      ...> |> Caracola.Presence.decode()
      {:ok, %{entity: "sip:alice@example.com", notes: [], tuples: [%{id: "a1", status: :open, contact: nil, priority: nil, note: nil, timestamp: nil}]}}
  """
  @spec encode(String.t(), [tuple_info()], keyword()) :: String.t()
  def encode(entity, tuples, opts \\ []) do
    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<presence xmlns="urn:ietf:params:xml:ns:pidf" entity="#{XML.escape(entity)}">\n),
      Enum.map(tuples, &encode_tuple/1),
      Enum.map(Keyword.get(opts, :notes, []), &["<note>", XML.escape(&1), "</note>\n"]),
      "</presence>\n"
    ])
  end

  defp encode_tuple(tuple) do
    contact =
      case {tuple[:contact], tuple[:priority]} do
        {nil, _} ->
          []

        {contact, nil} ->
          [XML.tag("contact", contact), "\n"]

        {contact, priority} ->
          [~s(<contact priority="#{XML.escape(priority)}">), XML.escape(contact), "</contact>\n"]
      end

    [
      ~s(<tuple id="#{XML.escape(tuple[:id] || Util.uid())}">\n),
      case tuple[:status] do
        nil -> "<status/>\n"
        status -> ["<status><basic>", Atom.to_string(status), "</basic></status>\n"]
      end,
      contact,
      if(tuple[:note], do: [XML.tag("note", tuple.note), "\n"], else: []),
      if(tuple[:timestamp], do: [XML.tag("timestamp", tuple.timestamp), "\n"], else: []),
      "</tuple>\n"
    ]
  end

  @doc "Parses a PIDF document."
  @spec decode(binary()) :: {:ok, document()} | :error
  def decode(body) do
    case XML.parse(body) do
      {:ok, {"presence", _, _} = root} ->
        {:ok,
         %{
           entity: XML.attr(root, "entity"),
           tuples: Enum.map(XML.children(root, "tuple"), &decode_tuple/1),
           notes: root |> XML.children("note") |> Enum.map(&XML.text/1) |> Enum.reject(&is_nil/1)
         }}

      _ ->
        :error
    end
  end

  defp decode_tuple(tuple) do
    contact = XML.child(tuple, "contact")

    status =
      case tuple |> XML.child("status") |> XML.child("basic") |> XML.text() do
        "open" -> :open
        "closed" -> :closed
        _ -> nil
      end

    %{
      id: XML.attr(tuple, "id"),
      status: status,
      contact: XML.text(contact),
      priority: XML.attr(contact, "priority"),
      note: XML.text(XML.child(tuple, "note")),
      timestamp: XML.text(XML.child(tuple, "timestamp"))
    }
  end

  @doc """
  The composite presence state of a presentity, from its current
  publications (see the module documentation).
  """
  @spec state(module(), Notifier.aor()) :: {String.t(), String.t()}
  def state(service, aor) do
    entity = Notifier.uri(aor)

    case EventCompositor.list(service, aor, "presence") do
      [{_tag, pub}] -> {@content_type, pub.data}
      [] -> {@content_type, encode(entity, [%{id: "default", status: :closed}])}
      pubs -> {@content_type, compose(entity, Enum.map(pubs, fn {_, pub} -> pub.data end))}
    end
  end

  # Tuples and notes of all the documents, the latest wins for each id
  defp compose(entity, bodies) do
    docs = for body <- bodies, {:ok, doc} <- [decode(body)], do: doc

    tuples =
      docs
      |> Enum.flat_map(& &1.tuples)
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.id)
      |> Enum.reverse()

    encode(entity, tuples, notes: docs |> Enum.flat_map(& &1.notes) |> Enum.uniq())
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config), do: {:ok, Notifier.add_events(config, ["presence"])}

  # Changes of the publications are notified to the watchers
  defcb sip_publish(%Message{event: {type, _}} = req, _call) do
    if Util.ascii_downcase(type) == "presence" do
      reply = EventCompositor.request(req)
      if match?({:ok, _}, reply), do: Notifier.notify(req.service, "presence", Notifier.aor(req))
      {:reply, reply}
    else
      :cont
    end
  end

  def sip_publish(_req, _call), do: :cont

  defcb sip_notifier_body("presence", aor, _version, service), do: state(service, aor)

  def sip_notifier_body(_event, _aor, _version, _service), do: :cont
end
