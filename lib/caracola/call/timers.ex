defmodule Caracola.Call.Timers do
  @moduledoc false
  # Transaction timers (RFC 3261 §17 and RFC 6026). Port of the timer part
  # of NkSIP's nksip_call_lib.
  #
  # Each transaction has up to three timers: a timeout timer (B, C, D, F, H,
  # I, J, K, L, M and the no-INVITE timeout), a retransmission timer (A, E, G)
  # and the expire timer (Expires header of INVITE requests). Timer messages
  # carry their reference, so that a timer cancelled too late is ignored.

  alias Caracola.Call
  alias Caracola.Call.{Trans, UAC, UAS}

  @long [:timer_b, :timer_f, :timer_m, :timer_h, :timer_j, :timer_l, :noinvite, :prack_timeout]

  @doc "Starts (or cancels, with `:cancel`) the timeout timer."
  def timeout(%Trans{} = trans, :cancel, _call),
    do: %{trans | timeout_timer: cancel(trans.timeout_timer)}

  def timeout(%Trans{} = trans, tag, %Call{config: config}) do
    cancel(trans.timeout_timer)

    time =
      cond do
        tag in @long -> 64 * t1(config)
        tag == :timer_d -> 32_000
        tag in [:timer_k, :timer_i] -> config[:timer_t4] || 5_000
        tag == :timer_c -> 1_000 * (config[:timer_c] || 180)
      end

    %{trans | timeout_timer: start(time, tag, trans)}
  end

  @doc "Starts (or cancels, with `:cancel`) the retransmission timer."
  def retrans(%Trans{} = trans, :cancel, _call),
    do: %{trans | retrans_timer: cancel(trans.retrans_timer)}

  def retrans(%Trans{} = trans, tag, %Call{config: config}) do
    cancel(trans.retrans_timer)
    time = trans.next_retrans || t1(config)

    next =
      case tag do
        :timer_a -> 2 * time
        _ -> min(2 * time, config[:timer_t2] || 4_000)
      end

    %{trans | retrans_timer: start(time, tag, trans), next_retrans: next}
  end

  @doc "Starts (or cancels) the expire timer of INVITE transactions."
  def expire(%Trans{} = trans, :cancel), do: %{trans | expire_timer: cancel(trans.expire_timer)}

  def expire(%Trans{request: req, opts: opts} = trans, :expire) do
    cancel(trans.expire_timer)

    timer =
      case req.expires do
        expires when is_integer(expires) and expires > 0 ->
          # The UAC fires first
          time = if trans.class == :uac, do: 1_000 * expires, else: 1_000 * expires + 100
          if :no_auto_expire not in opts, do: start(time, :expire, trans)

        _ ->
          nil
      end

    %{trans | expire_timer: timer}
  end

  @doc "Cancels all timers of a transaction."
  def cancel_all(%Trans{} = trans) do
    cancel(trans.timeout_timer)
    cancel(trans.retrans_timer)
    cancel(trans.expire_timer)
    %{trans | timeout_timer: nil, retrans_timer: nil, expire_timer: nil}
  end

  @doc false
  # Called when a timer message arrives
  def fired(class, tag, id, ref, %Call{} = call) do
    with {:ok, %Trans{class: ^class} = trans} <- Map.fetch(call.trans, id),
         true <- {tag, ref} in [trans.timeout_timer, trans.retrans_timer, trans.expire_timer] do
      trans = clear(trans, tag)

      case class do
        :uac -> UAC.timer(tag, trans, call)
        :uas -> UAS.timer(tag, trans, call)
      end
    else
      _ -> call
    end
  end

  defp clear(trans, tag) do
    cond do
      match?({^tag, _}, trans.timeout_timer) -> %{trans | timeout_timer: nil}
      match?({^tag, _}, trans.retrans_timer) -> %{trans | retrans_timer: nil}
      true -> %{trans | expire_timer: nil}
    end
  end

  defp t1(config), do: config[:timer_t1] || 500

  defp start(time, tag, %Trans{class: class, id: id}),
    do: {tag, :erlang.start_timer(round(time), self(), {class, tag, id})}

  defp cancel({_tag, ref}) do
    :erlang.cancel_timer(ref)
    nil
  end

  defp cancel(nil), do: nil
end
