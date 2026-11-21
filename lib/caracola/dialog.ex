defmodule Caracola.Dialog do
  @moduledoc """
  SIP dialogs (RFC 3261 §12). Equivalent to NkSIP's `nksip_dialog`.

  Dialogs are created by 101-299 responses to INVITE requests, and by 2xx
  responses to SUBSCRIBE, REFER and NOTIFY requests (see
  `Caracola.Subscription`), and live in the process of their call. They
  end when they have no INVITE usage and no subscriptions. They are identified by a `t:handle/0`, which
  is returned in the `:dialog` meta of the response (see `Caracola.UAC`) and
  can be obtained from any in-dialog message with `handle/1`. In-dialog
  requests are sent passing the handle instead of the service to the
  `Caracola.UAC` functions.

  Dialog changes are notified to the service with the callbacks
  `sip_dialog_update(event, dialog, call)` and
  `sip_session_update(event, dialog, call)`, see `Caracola`.
  """

  alias Caracola.{Call, Message, Reply, URI, Util}
  alias Caracola.Dialog.Invite

  @typedoc "Identifies a dialog inside a call."
  @type id :: String.t()

  @typedoc "Identifies a dialog: service, Call-ID and dialog id."
  @type handle :: {:dialog, module(), String.t(), id()}

  @typedoc "A dialog: its id, local and remote URIs and tags, route set, CSeqs, the INVITE usage and its subscriptions."
  @type t :: %__MODULE__{
          id: id(),
          service: module(),
          call_id: String.t(),
          created: integer(),
          updated: integer(),
          local_seq: non_neg_integer(),
          remote_seq: non_neg_integer(),
          local_uri: URI.t(),
          remote_uri: URI.t(),
          local_target: URI.t() | nil,
          remote_target: URI.t() | nil,
          route_set: [URI.t()],
          blocked_route_set: boolean(),
          early: boolean(),
          secure: boolean(),
          caller_tag: String.t(),
          invite: Invite.t() | nil,
          subscriptions: [Caracola.Subscription.t()],
          meta: map()
        }

  defstruct [
    :id,
    :service,
    :call_id,
    :created,
    :updated,
    :local_uri,
    :remote_uri,
    :local_target,
    :remote_target,
    :caller_tag,
    :invite,
    local_seq: 0,
    remote_seq: 0,
    route_set: [],
    subscriptions: [],
    blocked_route_set: false,
    early: true,
    secure: false,
    meta: %{session_expires: nil, refresh_timer: nil, min_se: nil}
  ]

  @doc """
  Returns the handle of a dialog, or of the dialog a message belongs to
  (`nil` if it does not belong to any).
  """
  @spec handle(t() | Message.t()) :: handle() | nil
  def handle(%__MODULE__{service: service, call_id: call_id, id: id}),
    do: {:dialog, service, call_id, id}

  def handle(%Message{service: service, call_id: call_id, dialog_id: id}) when is_binary(id),
    do: {:dialog, service, call_id, id}

  def handle(%Message{}), do: nil

  @doc "Gets the current state of a dialog."
  @spec get(handle()) :: {:ok, t()} | {:error, term()}
  def get({:dialog, service, call_id, id}),
    do: Call.query(service, call_id, {:get_dialog, id}, {:error, :unknown_dialog})

  @doc "Returns the handles of the dialogs of a call."
  @spec list(module(), String.t()) :: [handle()]
  def list(service, call_id), do: Call.query(service, call_id, :list_dialogs, [])

  @doc """
  Removes a dialog without sending any request (use `Caracola.UAC.bye/3` to
  hang up).
  """
  @spec stop(handle()) :: :ok | {:error, term()}
  def stop({:dialog, service, call_id, id}),
    do: Call.query(service, call_id, {:stop_dialog, id}, {:error, :unknown_dialog})

  @doc """
  Returns the origins (`{transport, ip, port}`) authorized in a dialog: the
  sources of requests that were authorized, and of 2xx responses. Requests
  from them get `:dialog` in the authorization list of `sip_authorize`.
  """
  @spec authorized(handle()) :: [{atom(), :inet.ip_address(), :inet.port_number()}]
  def authorized({:dialog, service, call_id, id}),
    do: Call.query(service, call_id, {:authorized, id}, [])

  @doc "Removes the authorized origins of a dialog."
  @spec clear_authorized(handle()) :: :ok
  def clear_authorized({:dialog, service, call_id, id}),
    do: Call.query(service, call_id, {:clear_authorized, id}, :ok)

  @doc false
  # Dialog id of a message for the local endpoint class: a hash of the remote
  # and local tags. For requests without To tag (dialog-creating requests
  # received), the tag our responses will have.
  @spec id(:uac | :uas, Message.t()) :: id() | nil
  def id(:uac, %Message{from_tag: from_tag, to_tag: to_tag})
      when is_binary(from_tag) and is_binary(to_tag),
      do: Util.hash({to_tag, from_tag})

  def id(:uas, %Message{from_tag: from_tag, to_tag: to_tag})
      when is_binary(from_tag) and is_binary(to_tag),
      do: Util.hash({from_tag, to_tag})

  def id(:uas, %Message{class: {:req, _}, from_tag: from_tag, to_tag: nil} = req)
      when is_binary(from_tag),
      do: Util.hash({from_tag, Reply.to_tag_candidate(req)})

  def id(_class, %Message{}), do: nil
end
