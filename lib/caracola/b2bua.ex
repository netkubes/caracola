defmodule Caracola.B2BUA do
  @moduledoc """
  Back-to-back user agent: bridges an incoming INVITE (the *A leg*) with a
  new outgoing one (the *B leg*), relaying the responses, the in-dialog
  requests and the hangups between both dialogs.

  ```
  defmodule MyB2BUA do
    use Malla.Service,
      plugins: [Caracola.B2BUA],
      sip: [listen: "sip:all:5060"]

    defcb sip_invite(req, _call),
      do: Caracola.B2BUA.bridge(req, "sip:bob@10.0.0.2", copy_headers: ["p-asserted-identity"])
  end
  ```

  `bridge/3` starts a process for the bridge and returns `:noreply`, a
  result for `sip_invite/2`: the B leg is sent from that process, and its
  provisional and final responses (with their SDP) are relayed to the A
  leg. Then:

    * BYEs are answered and sent to the other leg.
    * re-INVITEs, UPDATEs and INFOs are sent to the other leg, and its
      final response relayed back. A re-INVITE without SDP is answered with
      the last SDP sent to that leg.
    * A CANCEL of the A leg cancels the B leg.
    * When the INVITE usage of a leg ends for any other reason (a timeout,
      for example), the other leg is hung up.

  As both legs are separate dialogs, the B leg has its own Call-ID, tags,
  Via, Contact and route set: nothing of the A leg reaches it (topology
  hiding), except the From address and the headers in `:copy_headers`.
  Both early offer (SDP in the INVITE) and delayed offer (SDP in the 2xx
  and the ACK) are supported. 3xx responses are relayed as 480.

  Services implementing `sip_bye`, `sip_reinvite`, `sip_update`,
  `sip_info`, `sip_ack`, `sip_cancel` or `sip_dialog_update` must return
  `:cont` for the bridged calls, to let this plugin get them.

  ## Callbacks

    * `sip_b2bua_sdp(sdp, from, bridge)` - changes each `Caracola.SDP`
      relayed from the leg `from` (`:a` or `:b`) to the other one, for
      example to put a media relay in the middle. Returns the SDP to send
      (by default, the same).
    * `sip_b2bua_update(event, bridge)` - the bridge has changed: `:answered`
      or `{:stop, reason}`, where `reason` is `{:bye, leg}`,
      `{:rejected, code}`, `{:error, reason}`, `:cancelled`, `:hangup` or
      `{:dialog_stop, leg, reason}`. The result is ignored.

  Both are called in the process of the bridge, with a `t:t/0`.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  require Logger

  alias Caracola.{B2BUA.Bridge, Dialog, Message}

  @registry Caracola.B2BUA.Registry

  @typedoc "A leg of a bridge: `:a` is the caller, `:b` the callee."
  @type leg :: :a | :b

  @typedoc """
  A bridge: the Call-IDs and dialogs of both legs (the dialogs are set once
  answered), its status (`:calling` or `:answered`) and the `:meta` given
  to `bridge/3`.
  """
  @type t :: %__MODULE__{
          service: module(),
          a_call_id: String.t(),
          b_call_id: String.t(),
          a: Dialog.handle() | nil,
          b: Dialog.handle() | nil,
          status: :calling | :answered,
          meta: term()
        }

  defstruct [:service, :a_call_id, :b_call_id, :a, :b, :meta, status: :calling]

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Bridges an INVITE received in `sip_invite/2` with a new INVITE to `uri`,
  returning the result for `sip_invite/2` (`:noreply`).

  Options:

    * `{:from, from}` - From of the B leg (by default, the address of the
      From of the A leg).
    * `{:copy_headers, names}` - headers of the A leg to copy to the B leg.
    * `{:meta, term}` - kept in the bridge, for the callbacks.
    * Any other option is passed to `Caracola.UAC.invite/3` (as `:route`,
      `:password` or header options).
  """
  @spec bridge(Message.t(), String.t() | Caracola.URI.t(), list()) :: :noreply | {:reply, term()}
  def bridge(%Message{class: {:req, :invite}, to_tag: nil} = req, uri, opts \\ []) do
    case DynamicSupervisor.start_child(Caracola.B2BUA.Supervisor, {Bridge, {req, uri, opts}}) do
      {:ok, _pid} ->
        :noreply

      {:error, error} ->
        Logger.warning("could not start B2BUA bridge: #{inspect(error)}")
        {:reply, :internal_error}
    end
  end

  @doc "Gets the bridge of a call, by the Call-ID of any of its legs."
  @spec get(module(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(service, call_id), do: call(service, call_id, :get)

  @doc """
  Ends the bridge of a call: cancels the B leg if not answered yet (the A
  leg gets a 487), or hangs up both legs.
  """
  @spec hangup(module(), String.t()) :: :ok | {:error, :not_found}
  def hangup(service, call_id), do: call(service, call_id, :hangup)

  defp call(service, call_id, msg) do
    case find(service, call_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, msg)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc false
  def find(service, call_id) do
    case Registry.lookup(@registry, {service, call_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  ## ===================================================================
  ## Callbacks
  ## ===================================================================

  @doc false
  defcb sip_b2bua_sdp(sdp, _from, _bridge), do: sdp

  @doc false
  defcb sip_b2bua_update(_event, _bridge), do: :ok

  defcb sip_bye(req, call) do
    case notify(call, {:bye, req}) do
      :ok -> {:reply, :ok}
      :not_found -> :cont
    end
  end

  defcb sip_reinvite(req, call), do: forward(req, call)

  defcb sip_update(req, call), do: forward(req, call)

  defcb sip_info(req, call), do: forward(req, call)

  defcb sip_ack(req, call) do
    case notify(call, {:ack, req}) do
      :ok -> :ok
      :not_found -> :cont
    end
  end

  defcb sip_cancel(_invite_req, _cancel_req, call) do
    case notify(call, :cancel) do
      :ok -> :ok
      :not_found -> :cont
    end
  end

  defcb sip_dialog_update({:invite_status, {:stop, reason}}, dialog, call) do
    notify(call, {:dialog_stop, Dialog.handle(dialog), reason})
    :cont
  end

  def sip_dialog_update(_event, _dialog, _call), do: :cont

  defp forward(req, call) do
    case notify(call, {:request, req}) do
      :ok -> :noreply
      :not_found -> :cont
    end
  end

  defp notify(call, msg) do
    case find(call.service, call.call_id) do
      nil ->
        :not_found

      pid ->
        send(pid, {:leg, call.call_id, msg})
        :ok
    end
  end
end
