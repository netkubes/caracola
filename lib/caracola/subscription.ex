defmodule Caracola.Subscription do
  @moduledoc """
  Event subscriptions (RFC 6665). Equivalent to NkSIP's `nksip_subscription`.

  Subscriptions are created by 2xx responses to SUBSCRIBE (or REFER)
  requests, or by a NOTIFY arriving before that response, and live in a
  `Caracola.Dialog`, which can have several of them (and an INVITE usage).
  They are identified by a `t:handle/0`, returned in the `:subscription`
  meta of the response to SUBSCRIBE (see `Caracola.UAC`).

  `status` is `:init` (no NOTIFY yet), `:pending`, `:active` or
  `{:terminated, reason}`; terminated subscriptions are removed. Changes are
  notified with `sip_dialog_update({:subscription_status, status, subscription}, dialog, call)`,
  where `status` can also be `:middle_timer` (half of the expiration time,
  to refresh it), or `{:terminated, reason, retry_after}`.

  In-dialog SUBSCRIBE and NOTIFY requests for a subscription are sent
  passing its handle to `Caracola.UAC.subscribe/3` and
  `Caracola.UAC.notify/3`, which add the Event and, for NOTIFY, the
  Subscription-State headers (`{:subscription_state, state}` option,
  `:active` by default, with the remaining expiration time).
  """

  alias Caracola.{Dialog, Message, Tokens, Util}

  @typedoc "Identifies a subscription inside a dialog."
  @type id :: String.t()

  @typedoc "Identifies a subscription: service, Call-ID, dialog id and subscription id."
  @type handle :: {:subscription, module(), String.t(), Dialog.id(), id()}

  @typedoc "The reason a subscription ended (RFC 6665)."
  @type reason ::
          :deactivated
          | :probation
          | :rejected
          | :timeout
          | :giveup
          | :noresource
          | :invariant
          | :forced
          | {:code, pos_integer()}
          | nil

  @typedoc "The status of a subscription."
  @type status :: :init | :pending | :active | {:terminated, reason()}

  @typedoc "The state of a Subscription-State header."
  @type state ::
          :active
          | :pending
          | {:active | :pending, non_neg_integer() | nil}
          | {:terminated, reason()}
          | {:terminated, reason(), non_neg_integer() | nil}

  @typedoc "A subscription: its event, expiration, status and the dialog it belongs to."
  @type t :: %__MODULE__{
          id: id(),
          service: module(),
          call_id: String.t(),
          dialog_id: Dialog.id(),
          event: Tokens.token(),
          class: :uac | :uas,
          status: status(),
          expires: non_neg_integer() | nil,
          answered: integer() | nil,
          timer_n: {atom(), reference()} | nil,
          timer_expire: {atom(), reference()} | nil,
          timer_middle: {atom(), reference()} | nil
        }

  defstruct [
    :id,
    :service,
    :call_id,
    :dialog_id,
    :event,
    :class,
    :expires,
    :answered,
    :timer_n,
    :timer_expire,
    :timer_middle,
    status: :init
  ]

  @reasons ~w(deactivated probation rejected timeout giveup noresource invariant)a

  @doc "Returns the handle of a subscription."
  @spec handle(t()) :: handle()
  def handle(%__MODULE__{} = subs),
    do: {:subscription, subs.service, subs.call_id, subs.dialog_id, subs.id}

  @doc "Returns the handle of the dialog of a subscription."
  @spec dialog(handle()) :: Dialog.handle()
  def dialog({:subscription, service, call_id, dialog_id, _id}),
    do: {:dialog, service, call_id, dialog_id}

  @doc "Gets the current state of a subscription."
  @spec get(handle()) :: {:ok, t()} | {:error, term()}
  def get({:subscription, _, _, _, id} = handle) do
    with {:ok, dialog} <- Dialog.get(dialog(handle)) do
      case Enum.find(dialog.subscriptions, &(&1.id == id)) do
        nil -> {:error, :unknown_subscription}
        subs -> {:ok, subs}
      end
    end
  end

  @doc """
  Returns the handle of the subscription a SUBSCRIBE, NOTIFY or REFER (or
  one of their responses) belongs to, as the ones received in callbacks.
  For a new SUBSCRIBE, the subscription exists once it is answered with a
  2xx.
  """
  @spec handle_of(Message.t()) :: handle() | nil
  def handle_of(%Message{service: service, call_id: call_id, dialog_id: dialog_id} = msg)
      when is_binary(dialog_id),
      do: {:subscription, service, call_id, dialog_id, id(msg)}

  def handle_of(%Message{}), do: nil

  @doc false
  # Subscription id: the Event type and id, or the CSeq of the REFER
  def id(%Message{cseq: {cseq, :refer}}), do: Util.hash({"refer", Integer.to_string(cseq)})

  def id(%Message{event: {type, params}}) do
    id =
      case List.keyfind(params, "id", 0) do
        {_, id} -> id
        nil -> nil
      end

    Util.hash({Util.ascii_downcase(type), id})
  end

  def id(%Message{}), do: Util.hash({nil, nil})

  @doc false
  # Parses the Subscription-State header
  @spec state(Message.t()) :: state() | :invalid
  def state(%Message{} = msg) do
    with [value] <- Message.header(msg, "subscription-state"),
         {:ok, [{name, params}]} <- Tokens.parse(value) do
      parse_state(Util.ascii_downcase(name), params)
    else
      _ -> :invalid
    end
  end

  defp parse_state(name, params) when name in ["active", "pending"] do
    case param(params, "expires") do
      {:ok, expires} -> {String.to_existing_atom(name), expires}
      :error -> :invalid
    end
  end

  defp parse_state("terminated", params) do
    reason =
      case List.keyfind(params, "reason", 0) do
        {_, value} when is_binary(value) -> Enum.find(@reasons, &(Atom.to_string(&1) == value))
        _ -> nil
      end

    case param(params, "retry-after") do
      {:ok, retry} when reason in [:probation, :giveup] -> {:terminated, reason, retry}
      {:ok, _} -> {:terminated, reason, nil}
      :error -> :invalid
    end
  end

  defp parse_state(_name, _params), do: :invalid

  defp param(params, name) do
    case List.keyfind(params, name, 0) do
      nil ->
        {:ok, nil}

      {_, value} when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int >= 0 -> {:ok, int}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc false
  # Value of a Subscription-State header
  @spec encode_state(state()) :: {:ok, Tokens.token()} | :error
  def encode_state(state) when state in [:active, :pending],
    do: {:ok, {Atom.to_string(state), []}}

  def encode_state({state, expires}) when state in [:active, :pending] and is_integer(expires),
    do: {:ok, {Atom.to_string(state), [{"expires", Integer.to_string(max(expires, 0))}]}}

  def encode_state({state, nil}) when state in [:active, :pending], do: encode_state(state)

  def encode_state({:terminated, reason}) when reason in @reasons,
    do: {:ok, {"terminated", [{"reason", Atom.to_string(reason)}]}}

  def encode_state({:terminated, reason, nil}), do: encode_state({:terminated, reason})

  def encode_state({:terminated, reason, retry})
      when reason in [:probation, :giveup] and is_integer(retry) and retry > 0,
      do:
        {:ok,
         {"terminated",
          [{"reason", Atom.to_string(reason)}, {"retry-after", Integer.to_string(retry)}]}}

  def encode_state(_state), do: :error

  @doc false
  def find(%Dialog{subscriptions: subscriptions}, id),
    do: Enum.find(subscriptions, &(&1.id == id))
end
