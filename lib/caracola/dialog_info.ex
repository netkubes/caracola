defmodule Caracola.DialogInfo do
  @moduledoc """
  Dialog state (RFC 4235): the `dialog` event package, with
  `application/dialog-info+xml` documents, used by the busy lamp fields of
  phones and by call pickup.

  ```
  defmodule MyPBX do
    use Malla.Service,
      plugins: [Caracola.DialogInfo],
      sip: [listen: "sip:all:5060"]
  end
  ```

  The plugin is built on `Caracola.Notifier`: it accepts SUBSCRIBEs to the
  `dialog` event of any AOR (see `sip_notifier_authorize/4` there), and
  notifies the watchers of an AOR whenever one of its dialogs changes, with
  the full state (a new `version` for each NOTIFY of a subscription).

  The dialogs of an AOR are:

    * the INVITE dialogs of the service whose local URI (From for the
      dialogs it starts, To for the ones it receives) has that AOR, when
      `:track` is `true` (the default). This is the case of user agents
      and B2BUAs, whose dialogs go through `early` (a provisional response
      with a To tag), `confirmed` and `terminated`;
    * the ones set by the service with `put/3`, as a proxy that follows the
      calls of its users.

  Terminated dialogs are notified once and forgotten.

  Watchers read the NOTIFYs with `decode/1`.

  ## Configuration

  Under the `:dialog_info` key:

    * `:track` - follow the INVITE dialogs of the service (default `true`).
  """

  use Malla.Plugin, plugin_deps: [Caracola.Notifier]

  alias Caracola.{Dialog, Notifier, URI, Util, XML}
  alias Caracola.Dialog.Invite

  @content_type "application/dialog-info+xml"
  @event "dialog"

  @schema NimbleOptions.new!(
            track: [
              type: :boolean,
              default: true,
              doc: "Follow the INVITE dialogs of the service."
            ]
          )

  @typedoc "The state of a dialog in a dialog-info document (RFC 4235)."
  @type state :: :trying | :proceeding | :early | :confirmed | :terminated

  @typedoc "A participant of a dialog: its identity (a URI), display name and target URI."
  @type participant :: %{
          optional(:identity) => String.t() | nil,
          optional(:display) => String.t() | nil,
          optional(:target) => String.t() | nil
        }

  @typedoc """
  A dialog. `:id` and `:state` are required when encoding; `:event` and
  `:code` are the reason of the `terminated` state (as `"rejected"` and
  486).
  """
  @type dialog_info :: %{
          optional(:id) => String.t(),
          optional(:state) => state(),
          optional(:call_id) => String.t() | nil,
          optional(:local_tag) => String.t() | nil,
          optional(:remote_tag) => String.t() | nil,
          optional(:direction) => :initiator | :recipient | nil,
          optional(:event) => String.t() | nil,
          optional(:code) => pos_integer() | nil,
          optional(:local) => participant() | nil,
          optional(:remote) => participant() | nil
        }

  @typedoc "A decoded dialog-info document."
  @type document :: %{
          entity: String.t() | nil,
          version: non_neg_integer() | nil,
          state: :full | :partial | nil,
          dialogs: [dialog_info()]
        }

  @states ~w(trying proceeding early confirmed terminated)a

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc "The content type of dialog-info documents."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc """
  Sets the state of a dialog of an AOR (by its `:id`) and notifies the
  watchers, if it has changed. A `terminated` dialog is notified once and
  forgotten.
  """
  @spec put(module(), Notifier.aor(), dialog_info()) :: :ok
  def put(service, aor, %{id: id, state: state} = dialog) when state in @states do
    current = Map.new(Notifier.items(service, @event, aor))

    if Map.get(current, id) == dialog do
      :ok
    else
      Notifier.put_item(service, @event, aor, id, dialog)

      if state == :terminated,
        do: Notifier.notify(service, @event, aor, then: fn -> forget(service, aor, id) end),
        else: Notifier.notify(service, @event, aor)
    end
  end

  # Unless it has been used again
  defp forget(service, aor, id) do
    case List.keyfind(Notifier.items(service, @event, aor), id, 0) do
      {_, %{state: :terminated}} -> Notifier.put_item(service, @event, aor, id, nil)
      _ -> :ok
    end
  end

  @doc "The current dialogs of an AOR."
  @spec dialogs(module(), Notifier.aor()) :: [dialog_info()]
  def dialogs(service, aor) do
    for {_id, dialog} <- Notifier.items(service, @event, aor), do: dialog
  end

  @doc """
  Builds a dialog-info document with the full state.

      iex> body = Caracola.DialogInfo.encode("sip:bob@example.com", 3, [%{id: "d1", state: :early, direction: :recipient}])
      iex> {:ok, %{version: 3, state: :full, dialogs: [%{id: "d1", state: :early}]}} = Caracola.DialogInfo.decode(body)
  """
  @spec encode(String.t(), non_neg_integer(), [dialog_info()]) :: String.t()
  def encode(entity, version, dialogs) do
    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<dialog-info xmlns="urn:ietf:params:xml:ns:dialog-info" version="#{version}" ),
      ~s(state="full" entity="#{XML.escape(entity)}">\n),
      Enum.map(dialogs, &encode_dialog/1),
      "</dialog-info>\n"
    ])
  end

  defp encode_dialog(dialog) do
    attrs =
      for {key, name} <- [
            id: "id",
            call_id: "call-id",
            local_tag: "local-tag",
            remote_tag: "remote-tag",
            direction: "direction"
          ],
          value = dialog[key],
          value != nil,
          do: [?\s, name, "=\"", XML.escape(to_string(value)), ?"]

    reason =
      for {key, name} <- [event: "event", code: "code"],
          value = dialog[key],
          value != nil,
          do: [?\s, name, "=\"", XML.escape(to_string(value)), ?"]

    [
      "<dialog",
      attrs,
      ">\n<state",
      reason,
      ">",
      Atom.to_string(dialog.state),
      "</state>\n",
      encode_participant("local", dialog[:local]),
      encode_participant("remote", dialog[:remote]),
      "</dialog>\n"
    ]
  end

  defp encode_participant(_name, nil), do: []

  defp encode_participant(name, participant) do
    identity =
      case {participant[:identity], participant[:display]} do
        {nil, _} ->
          []

        {id, nil} ->
          XML.tag("identity", id)

        {id, display} ->
          [~s(<identity display="#{XML.escape(display)}">), XML.escape(id), "</identity>"]
      end

    target =
      case participant[:target] do
        nil -> []
        target -> ~s(<target uri="#{XML.escape(target)}"/>)
      end

    ["<", name, ">", identity, target, "</", name, ">\n"]
  end

  @doc "Parses a dialog-info document."
  @spec decode(binary()) :: {:ok, document()} | :error
  def decode(body) do
    case XML.parse(body) do
      {:ok, {"dialog-info", _, _} = root} ->
        {:ok,
         %{
           entity: XML.attr(root, "entity"),
           version: integer(XML.attr(root, "version")),
           state:
             case XML.attr(root, "state") do
               "full" -> :full
               "partial" -> :partial
               _ -> nil
             end,
           dialogs: Enum.map(XML.children(root, "dialog"), &decode_dialog/1)
         }}

      _ ->
        :error
    end
  end

  defp decode_dialog(dialog) do
    state = XML.child(dialog, "state")

    %{
      id: XML.attr(dialog, "id"),
      state: Enum.find(@states, &(Atom.to_string(&1) == XML.text(state))),
      call_id: XML.attr(dialog, "call-id"),
      local_tag: XML.attr(dialog, "local-tag"),
      remote_tag: XML.attr(dialog, "remote-tag"),
      direction:
        case XML.attr(dialog, "direction") do
          "initiator" -> :initiator
          "recipient" -> :recipient
          _ -> nil
        end,
      event: XML.attr(state, "event"),
      code: integer(XML.attr(state, "code")),
      local: decode_participant(XML.child(dialog, "local")),
      remote: decode_participant(XML.child(dialog, "remote"))
    }
  end

  defp decode_participant(nil), do: nil

  defp decode_participant(participant) do
    identity = XML.child(participant, "identity")

    %{
      identity: XML.text(identity),
      display: XML.attr(identity, "display"),
      target: XML.attr(XML.child(participant, "target"), "uri")
    }
  end

  defp integer(nil), do: nil

  defp integer(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <- NimbleOptions.validate(Keyword.get(config, :dialog_info, []), @schema) do
      {:ok, config |> Keyword.put(:dialog_info, opts) |> Notifier.add_events([@event])}
    end
  end

  defcb sip_notifier_body("dialog", aor, version, service),
    do: {@content_type, encode(Notifier.uri(aor), version, dialogs(service, aor))}

  def sip_notifier_body(_event, _aor, _version, _service), do: :cont

  # The INVITE dialogs of the service
  defcb caracola_callback(:sip_dialog_update, [event, %Dialog{} = dialog, call]) do
    with {:ok, state} <- state(event, dialog),
         true <- track?(call.service) do
      put(call.service, aor(dialog), info(dialog, state))
    end

    :cont
  end

  def caracola_callback(_fun, _args), do: :cont

  # :start is the first update (with a provisional or a 2xx response)
  defp state({:invite_status, {:stop, _reason}}, _dialog), do: {:ok, :terminated}

  defp state(event, %Dialog{invite: %Invite{status: status}})
       when event in [:start, :target_update] or elem(event, 0) == :invite_status do
    case status do
      status when status in [:proceeding_uac, :proceeding_uas] -> {:ok, :early}
      :bye -> {:ok, :terminated}
      _ -> {:ok, :confirmed}
    end
  end

  defp state(_event, _dialog), do: :none

  defp track?(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> get_in(config, [:dialog_info, :track]) != false
      _ -> false
    end
  end

  defp aor(%Dialog{local_uri: uri}), do: {uri.scheme, uri.user, uri.domain}

  defp info(%Dialog{invite: %Invite{} = invite} = dialog, state) do
    direction =
      case invite do
        %Invite{class: :uac} -> :initiator
        %Invite{class: :uas} -> :recipient
        %Invite{status: :proceeding_uac} -> :initiator
        _ -> :recipient
      end

    %{
      id: dialog.id,
      state: state,
      call_id: dialog.call_id,
      local_tag: tag(dialog.local_uri),
      remote_tag: tag(dialog.remote_uri),
      direction: direction,
      local: participant(dialog.local_uri, dialog.local_target),
      remote: participant(dialog.remote_uri, dialog.remote_target)
    }
  end

  defp tag(uri), do: Util.opt(uri.ext_params, "tag")

  defp participant(uri, target) do
    %{
      identity: uri_string(%{uri | port: nil, params: []}),
      display: if(uri.disp in [nil, ""], do: nil, else: String.trim(uri.disp, "\"")),
      target: if(target, do: uri_string(target))
    }
  end

  defp uri_string(uri), do: IO.iodata_to_binary(URI.encode_ruri(uri))
end
