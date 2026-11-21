defmodule Caracola.Call.Trans do
  @moduledoc false
  # A client (UAC) or server (UAS) transaction. Equivalent to NkSIP's #trans{}.

  alias Caracola.Message

  @type status ::
          :invite_calling
          | :invite_proceeding
          | :invite_accepted
          | :invite_completed
          | :invite_confirmed
          | :trying
          | :proceeding
          | :completed
          | :ack
          | :finished

  @type timer :: {atom(), reference()} | nil

  @type t :: %__MODULE__{
          id: pos_integer(),
          class: :uac | :uas,
          status: status(),
          from: GenServer.from() | {:fork, pos_integer()} | nil,
          opts: list(),
          trans_id: integer() | nil,
          request: Message.t() | nil,
          method: Message.method(),
          ruri: Caracola.URI.t() | nil,
          transport: atom() | nil,
          response: Message.t() | nil,
          code: non_neg_integer(),
          to_tags: [String.t()],
          stateless: boolean(),
          cancel: nil | :to_cancel | :cancelled,
          loop_id: integer() | nil,
          timeout_timer: timer(),
          retrans_timer: timer(),
          next_retrans: non_neg_integer() | nil,
          iter: non_neg_integer(),
          rseq: non_neg_integer(),
          prack: {pos_integer(), pos_integer(), Message.method()} | nil,
          pracks: [tuple()],
          expire_timer: timer(),
          start_time: integer() | nil
        }

  defstruct [
    :id,
    :class,
    :status,
    :from,
    :trans_id,
    :request,
    :method,
    :ruri,
    :transport,
    :response,
    :cancel,
    :loop_id,
    :timeout_timer,
    :retrans_timer,
    :next_retrans,
    :expire_timer,
    :start_time,
    opts: [],
    code: 0,
    iter: 0,
    rseq: 0,
    prack: nil,
    pracks: [],
    to_tags: [],
    stateless: false
  ]
end
