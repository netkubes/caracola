defmodule Caracola.Dialog.Invite do
  @moduledoc """
  The INVITE usage of a dialog: the last INVITE transaction and the state
  of the session. Equivalent to NkSIP's `#invite{}`.

  `status` moves through `:proceeding_uac | :proceeding_uas` (provisional
  responses), `:accepted_uac | :accepted_uas` (2xx response sent or
  received, waiting for the ACK), `:confirmed` (ACK sent or received) and
  `:bye` (BYE sent or received).

  `local_sdp` and `remote_sdp` are the current session descriptions, once
  an offer/answer exchange has been completed.
  """

  alias Caracola.{Message, SDP}

  @typedoc "The status of the INVITE usage of a dialog, and which side (UAC or UAS) is in it."
  @type status ::
          :proceeding_uac
          | :proceeding_uas
          | :accepted_uac
          | :accepted_uas
          | :confirmed
          | :bye

  @typedoc "Pending offer or answer: who sent it, in which method, and the SDP."
  @type sdp_offer :: {:local | :remote, Message.method(), SDP.t()} | nil

  @typedoc "The INVITE usage of a dialog: status, class, requests and responses, SDP and timers."
  @type t :: %__MODULE__{
          status: status(),
          class: :uac | :uas | nil,
          answered: integer() | nil,
          request: Message.t() | nil,
          response: Message.t() | nil,
          ack: Message.t() | nil,
          local_sdp: SDP.t() | nil,
          remote_sdp: SDP.t() | nil,
          media_started: boolean(),
          sdp_offer: sdp_offer(),
          sdp_answer: sdp_offer(),
          timeout_timer: {atom(), reference()} | nil,
          retrans_timer: {atom(), reference()} | nil,
          next_retrans: non_neg_integer() | nil
        }

  defstruct [
    :status,
    :class,
    :answered,
    :request,
    :response,
    :ack,
    :local_sdp,
    :remote_sdp,
    :sdp_offer,
    :sdp_answer,
    :timeout_timer,
    :retrans_timer,
    :next_retrans,
    media_started: false
  ]
end
