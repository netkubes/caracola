defmodule Caracola.Replaces do
  @moduledoc """
  The Replaces header (RFC 3891): a new INVITE replaces an existing dialog,
  as in attended transfers and call pickup.

  ```
  defmodule MyUA do
    use Malla.Service,
      plugins: [Caracola.Replaces, Caracola.Refer],
      sip: [listen: "sip:all:5060"]
  end
  ```

  The plugin adds `replaces` to the Supported header. When a new INVITE
  with a Replaces header arrives, it looks for the replaced dialog (in any
  call of the service), and rejects the INVITE:

    * with 481 if there is no such dialog, or it is an early dialog this UA
      did not start;
    * with 486 if it has `early-only` and the dialog is confirmed;
    * with 603 if the dialog has already been hung up;
    * with 400 if the header is invalid.

  Otherwise `sip_invite/2` is called as usual (`replaced/1` returns the
  handle of the replaced dialog), and once the new dialog is confirmed
  (its ACK is received), the replaced one is ended: with a BYE if it was
  confirmed, or a CANCEL if it was an early dialog this UA started.

  To replace a dialog of another UA, send an INVITE with the header of
  `header/1`, or, for an attended transfer, a REFER with the Refer-To of
  `refer_to/2`:

  ```
  # A is talking to B (dialog_b) and to C (dialog_c), and transfers B to C
  {:ok, refer_to} = Caracola.Replaces.refer_to("sip:c@example.com", dialog_c)
  Caracola.UAC.refer(dialog_b, refer_to: refer_to)
  ```
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  require Logger

  alias Caracola.{Dialog, Message, UAC}
  alias Caracola.Dialog.{Invite, Ref}

  @impl true
  def plugin_config(_srv_id, config),
    do: {:ok, Caracola.Config.add_values(config, :supported, ["replaces"])}

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  The value of a Replaces header for a dialog of this UA, to be sent to its
  remote party or to a third UA (the tags as seen by the remote party).
  """
  @spec header(Dialog.handle()) :: {:ok, String.t()} | {:error, term()}
  def header(dialog), do: Ref.value(dialog)

  @doc """
  The Refer-To of an attended transfer: `uri` (the remote party of
  `dialog`) with a Replaces header for `dialog`.
  """
  @spec refer_to(String.t(), Dialog.handle()) :: {:ok, String.t()} | {:error, term()}
  def refer_to(uri, dialog), do: Ref.refer_to(uri, "Replaces", dialog)

  @doc """
  The handle of the dialog a received INVITE replaces (`nil` if it has no
  valid Replaces header).
  """
  @spec replaced(Message.t()) :: Dialog.handle() | nil
  def replaced(%Message{} = req), do: Ref.handle(req, "replaces")

  ## ===================================================================
  ## Callbacks
  ## ===================================================================

  defcb caracola_callback(:sip_invite, [req, call]) do
    case check(req, call) do
      :ok -> :cont
      {:error, reply} -> {:done, {:reply, reply}}
    end
  end

  # The replaced dialog is ended once the new one is confirmed
  def caracola_callback(:sip_dialog_update, [{:invite_status, :confirmed}, dialog, _call]) do
    with %Invite{class: :uas, request: %Message{} = req} <- dialog.invite,
         {:dialog, _, _, _} = replaced <- replaced(req) do
      spawn(fn -> hang_up(replaced) end)
    end

    :cont
  end

  def caracola_callback(_fun, _args), do: :cont

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp check(%Message{to_tag: nil} = req, call) do
    case Ref.parse(req, "replaces") do
      :none ->
        :ok

      :error ->
        {:error, {:invalid_request, "Invalid Replaces"}}

      {:ok, call_id, id, params} ->
        call_id
        |> Ref.find(id, call)
        |> check_dialog(List.keymember?(params, "early-only", 0))
    end
  end

  defp check(_req, _call), do: :ok

  defp check_dialog(%Dialog{invite: %Invite{status: status}}, early_only?) do
    cond do
      status == :bye -> {:error, :decline}
      status == :proceeding_uas -> {:error, :no_transaction}
      status == :proceeding_uac -> :ok
      early_only? -> {:error, :busy}
      true -> :ok
    end
  end

  defp check_dialog(_dialog, _early_only?), do: {:error, :no_transaction}

  defp hang_up({:dialog, service, call_id, _} = replaced) do
    case Dialog.get(replaced) do
      {:ok, %Dialog{invite: %Invite{status: :proceeding_uac, request: req}}} ->
        UAC.cancel({service, call_id, req.id})

      {:ok, %Dialog{invite: %Invite{status: status}}} when status != :bye ->
        UAC.bye(replaced)

      _ ->
        :ok
    end
  rescue
    error -> Logger.warning("could not end replaced dialog: " <> Exception.message(error))
  end
end
