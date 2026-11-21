defmodule Caracola.Conference do
  @moduledoc """
  Conference state (RFC 4575): the `conference` event package, with
  `application/conference-info+xml` documents, with the description and
  the participants of a conference.

  ```
  defmodule MyFocus do
    use Malla.Service,
      plugins: [Caracola.Conference, Caracola.Join],
      sip: [listen: "sip:all:5060"]
  end

  conf = {:sip, "room1", "example.com"}
  Caracola.Conference.put_description(MyFocus, conf, %{subject: "Weekly"})

  Caracola.Conference.put_user(MyFocus, conf, %{
    entity: "sip:alice@example.com",
    display: "Alice",
    status: :connected,
    media: [%{id: "1", type: "audio", status: "sendrecv"}]
  })
  ```

  The plugin is built on `Caracola.Notifier`: it accepts SUBSCRIBEs to the
  `conference` event of any AOR (see `sip_notifier_authorize/4` there),
  and notifies the watchers of a conference with its full state whenever
  the service changes it. Running the conference (the focus and the
  mixer) is up to the application.

  Users are identified by their `:entity` (a URI). `remove_user/3`
  notifies a user as `disconnected` once, and forgets it. The user count
  of the conference state is the number of users that are not
  disconnected.

  Watchers read the NOTIFYs with `decode/1`.
  """

  use Malla.Plugin, plugin_deps: [Caracola.Notifier]

  alias Caracola.{Notifier, XML}

  @content_type "application/conference-info+xml"
  @event "conference"

  @statuses Map.new(
              ~w(pending dialing-out dialing-in alerting on-hold connected muted-via-focus disconnecting disconnected),
              &{&1, &1 |> String.replace("-", "_") |> String.to_atom()}
            )

  @typedoc "The status of a participant of a conference."
  @type status ::
          :pending
          | :dialing_out
          | :dialing_in
          | :alerting
          | :on_hold
          | :connected
          | :muted_via_focus
          | :disconnecting
          | :disconnected

  @typedoc ~s(A media stream of a user: `:type` as `"audio"`, `:status` as `"sendrecv"`.)
  @type media :: %{
          optional(:id) => String.t(),
          optional(:type) => String.t() | nil,
          optional(:status) => String.t() | nil
        }

  @typedoc """
  A participant. `:endpoint` is the URI of its device (its `:entity` by
  default), and `:joining_method` is `"dialed-in"`, `"dialed-out"` or
  `"focus-owner"`.
  """
  @type user :: %{
          optional(:entity) => String.t(),
          optional(:display) => String.t() | nil,
          optional(:endpoint) => String.t() | nil,
          optional(:status) => status() | nil,
          optional(:joining_method) => String.t() | nil,
          optional(:media) => [media()]
        }

  @typedoc "The description of a conference."
  @type description :: %{
          optional(:subject) => String.t() | nil,
          optional(:display) => String.t() | nil,
          optional(:max_users) => pos_integer() | nil,
          optional(:locked) => boolean() | nil
        }

  @typedoc "A decoded conference-info document."
  @type document :: %{
          entity: String.t() | nil,
          version: non_neg_integer() | nil,
          state: :full | :partial | :deleted | nil,
          description: description(),
          user_count: non_neg_integer() | nil,
          active: boolean() | nil,
          locked: boolean() | nil,
          users: [user()]
        }

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc "The content type of conference-info documents."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc """
  Sets the description of a conference, and notifies the watchers if it
  has changed.
  """
  @spec put_description(module(), Notifier.aor(), description()) :: :ok
  def put_description(service, aor, description) when is_map(description),
    do: put(service, aor, :description, description)

  @doc "The description of a conference."
  @spec description(module(), Notifier.aor()) :: description()
  def description(service, aor) do
    case List.keyfind(Notifier.items(service, @event, aor), :description, 0) do
      {_, description} -> description
      nil -> %{}
    end
  end

  @doc """
  Adds or updates a user of a conference (by its `:entity`), and notifies
  the watchers if it has changed.
  """
  @spec put_user(module(), Notifier.aor(), user()) :: :ok
  def put_user(service, aor, %{entity: entity} = user) when is_binary(entity),
    do: put(service, aor, {:user, entity}, user)

  @doc """
  Removes a user of a conference: it is notified once as `disconnected`,
  and forgotten.
  """
  @spec remove_user(module(), Notifier.aor(), String.t()) :: :ok
  def remove_user(service, aor, entity) do
    case List.keyfind(Notifier.items(service, @event, aor), {:user, entity}, 0) do
      {key, user} ->
        Notifier.put_item(service, @event, aor, key, %{user | status: :disconnected})
        Notifier.notify(service, @event, aor, then: fn -> forget(service, aor, key) end)

      nil ->
        :ok
    end
  end

  # Unless it has been added again
  defp forget(service, aor, key) do
    case List.keyfind(Notifier.items(service, @event, aor), key, 0) do
      {_, %{status: :disconnected}} -> Notifier.put_item(service, @event, aor, key, nil)
      _ -> :ok
    end
  end

  @doc "The users of a conference."
  @spec users(module(), Notifier.aor()) :: [user()]
  def users(service, aor) do
    for {{:user, _}, user} <- Notifier.items(service, @event, aor), do: user
  end

  defp put(service, aor, key, value) do
    case List.keyfind(Notifier.items(service, @event, aor), key, 0) do
      {_, ^value} ->
        :ok

      _ ->
        Notifier.put_item(service, @event, aor, key, value)
        Notifier.notify(service, @event, aor)
    end
  end

  @doc """
  Builds a conference-info document with the full state.

      iex> body = Caracola.Conference.encode("sip:room@example.com", 1, %{subject: "Hi"}, [%{entity: "sip:a@example.com", status: :connected}])
      iex> {:ok, doc} = Caracola.Conference.decode(body)
      iex> {doc.version, doc.description.subject, doc.user_count, doc.users}
      {1, "Hi", 1, [%{entity: "sip:a@example.com", display: nil, endpoint: "sip:a@example.com", status: :connected, joining_method: nil, media: []}]}
  """
  @spec encode(String.t(), non_neg_integer(), description(), [user()]) :: String.t()
  def encode(entity, version, description, users) do
    count = Enum.count(users, &(&1[:status] != :disconnected))

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<conference-info xmlns="urn:ietf:params:xml:ns:conference-info" ),
      ~s(entity="#{XML.escape(entity)}" state="full" version="#{version}">\n),
      encode_description(description),
      "<conference-state>",
      XML.tag("user-count", Integer.to_string(count)),
      XML.tag("active", to_string(count > 0)),
      XML.tag("locked", to_string(description[:locked] == true)),
      "</conference-state>\n<users>\n",
      Enum.map(users, &encode_user/1),
      "</users>\n</conference-info>\n"
    ])
  end

  defp encode_description(description) do
    max = description[:max_users] && Integer.to_string(description[:max_users])

    [
      "<conference-description>",
      XML.tag("display-text", description[:display]),
      XML.tag("subject", description[:subject]),
      XML.tag("maximum-user-count", max),
      "</conference-description>\n"
    ]
  end

  defp encode_user(user) do
    endpoint = user[:endpoint] || user.entity

    status =
      case user[:status] do
        nil -> nil
        status -> status |> Atom.to_string() |> String.replace("_", "-")
      end

    media =
      for m <- user[:media] || [] do
        [
          ~s(<media id="#{XML.escape(m[:id] || "")}">),
          XML.tag("type", m[:type]),
          XML.tag("status", m[:status]),
          "</media>"
        ]
      end

    [
      ~s(<user entity="#{XML.escape(user.entity)}" state="full">),
      XML.tag("display-text", user[:display]),
      ~s(<endpoint entity="#{XML.escape(endpoint)}">),
      XML.tag("status", status),
      XML.tag("joining-method", user[:joining_method]),
      media,
      "</endpoint></user>\n"
    ]
  end

  @doc "Parses a conference-info document."
  @spec decode(binary()) :: {:ok, document()} | :error
  def decode(body) do
    case XML.parse(body) do
      {:ok, {"conference-info", _, _} = root} ->
        desc = XML.child(root, "conference-description")
        state = XML.child(root, "conference-state")

        {:ok,
         %{
           entity: XML.attr(root, "entity"),
           version: integer(XML.attr(root, "version")),
           state:
             case XML.attr(root, "state") do
               "full" -> :full
               "partial" -> :partial
               "deleted" -> :deleted
               _ -> nil
             end,
           description: %{
             display: XML.text(XML.child(desc, "display-text")),
             subject: XML.text(XML.child(desc, "subject")),
             max_users: integer(XML.text(XML.child(desc, "maximum-user-count")))
           },
           user_count: integer(XML.text(XML.child(state, "user-count"))),
           active: boolean(XML.text(XML.child(state, "active"))),
           locked: boolean(XML.text(XML.child(state, "locked"))),
           users:
             for(
               users <- [XML.child(root, "users")],
               users != nil,
               user <- XML.children(users, "user"),
               do: decode_user(user)
             )
         }}

      _ ->
        :error
    end
  end

  # The first endpoint of each user
  defp decode_user(user) do
    endpoint = XML.child(user, "endpoint")

    media =
      for m <- if(endpoint, do: XML.children(endpoint, "media"), else: []) do
        %{
          id: XML.attr(m, "id"),
          type: XML.text(XML.child(m, "type")),
          status: XML.text(XML.child(m, "status"))
        }
      end

    %{
      entity: XML.attr(user, "entity"),
      display: XML.text(XML.child(user, "display-text")),
      endpoint: XML.attr(endpoint, "entity"),
      status: status(XML.text(XML.child(endpoint, "status"))),
      joining_method: XML.text(XML.child(endpoint, "joining-method")),
      media: media
    }
  end

  defp status(value), do: Map.get(@statuses, value)

  defp integer(nil), do: nil

  defp integer(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp boolean("true"), do: true
  defp boolean("1"), do: true
  defp boolean("false"), do: false
  defp boolean("0"), do: false
  defp boolean(_value), do: nil

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config), do: {:ok, Notifier.add_events(config, [@event])}

  defcb sip_notifier_body("conference", aor, version, service) do
    body = encode(Notifier.uri(aor), version, description(service, aor), users(service, aor))
    {@content_type, body}
  end

  def sip_notifier_body(_event, _aor, _version, _service), do: :cont
end
