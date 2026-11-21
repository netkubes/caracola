defmodule Caracola.Join do
  @moduledoc """
  The Join header (RFC 3911): a new INVITE joins an existing dialog, as in
  barge-in, call monitoring or ad hoc conferences.

  ```
  defmodule MyUA do
    use Malla.Service,
      plugins: [Caracola.Join, Caracola.Refer],
      sip: [listen: "sip:all:5060"]
  end
  ```

  The plugin adds `join` to the Supported header. When a new INVITE with a
  Join header arrives, it looks for the joined dialog (in any call of the
  service), and rejects the INVITE:

    * with 481 if there is no such dialog, it is not an INVITE dialog, or
      it is an early dialog this UA did not start;
    * with 603 if the dialog has already been hung up;
    * with 400 if the header is invalid, or the INVITE has a Replaces
      header too.

  Otherwise `sip_invite/2` is called as usual, and `joined/1` returns the
  handle of the joined dialog. Joining the sessions (mixing their media, or
  becoming a conference focus) is up to the application, which can also
  reject the INVITE (for example with 488 if it can not mix them). Unlike
  Replaces, the joined dialog goes on.

  To join a dialog of another UA, send an INVITE with the header of
  `header/1`, or ask a third UA to do it with a REFER with the Refer-To of
  `refer_to/2`:

  ```
  # A is talking to C (dialog_c), and asks B to join the call at C
  {:ok, refer_to} = Caracola.Join.refer_to("sip:c@example.com", dialog_c)
  Caracola.UAC.refer(dialog_b, refer_to: refer_to)
  ```
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.{Dialog, Message}
  alias Caracola.Dialog.{Invite, Ref}

  @impl true
  def plugin_config(_srv_id, config),
    do: {:ok, Caracola.Config.add_values(config, :supported, ["join"])}

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  The value of a Join header for a dialog of this UA, to be sent to its
  remote party or to a third UA (the tags as seen by the remote party).
  """
  @spec header(Dialog.handle()) :: {:ok, String.t()} | {:error, term()}
  def header(dialog), do: Ref.value(dialog)

  @doc "The Refer-To asking to join `dialog` at `uri` (its remote party)."
  @spec refer_to(String.t(), Dialog.handle()) :: {:ok, String.t()} | {:error, term()}
  def refer_to(uri, dialog), do: Ref.refer_to(uri, "Join", dialog)

  @doc """
  The handle of the dialog a received INVITE joins (`nil` if it has no
  valid Join header).
  """
  @spec joined(Message.t()) :: Dialog.handle() | nil
  def joined(%Message{} = req), do: Ref.handle(req, "join")

  ## ===================================================================
  ## Callbacks
  ## ===================================================================

  defcb caracola_callback(:sip_invite, [req, call]) do
    case check(req, call) do
      :ok -> :cont
      {:error, reply} -> {:done, {:reply, reply}}
    end
  end

  def caracola_callback(_fun, _args), do: :cont

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp check(%Message{to_tag: nil} = req, call) do
    case Ref.parse(req, "join") do
      :none ->
        :ok

      :error ->
        {:error, {:invalid_request, "Invalid Join"}}

      {:ok, call_id, id, _params} ->
        if Message.header(req, "replaces") != [],
          do: {:error, {:invalid_request, "Join with Replaces"}},
          else: call_id |> Ref.find(id, call) |> check_dialog()
    end
  end

  defp check(_req, _call), do: :ok

  defp check_dialog(%Dialog{invite: %Invite{status: status}}) do
    case status do
      :bye -> {:error, :decline}
      :proceeding_uas -> {:error, :no_transaction}
      _ -> :ok
    end
  end

  defp check_dialog(_dialog), do: {:error, :no_transaction}
end
