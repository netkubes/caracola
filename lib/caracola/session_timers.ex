defmodule Caracola.SessionTimers do
  @moduledoc """
  Session timers (RFC 4028). Equivalent to NkSIP's `nksip_timers`.

  ```
  defmodule MyUA do
    use Malla.Service,
      plugins: [Caracola.SessionTimers],
      sip: [listen: "sip:all:5060", session_expires: 1800, min_se: 90]
  end
  ```

  The plugin adds `timer` to the Supported header. With it, INVITE and
  UPDATE transactions negotiate a session interval:

    * Requests can propose one with `{:session_expires, interval}` or
      `{:session_expires, {interval, :uac | :uas}}` (the refresher), and a
      `{:min_se, interval}`. In-dialog requests get the current interval
      automatically. A 422 (interval too small) is answered sending the
      request again with the Min-SE of the response.
    * Requests with an interval below the `:min_se` of the service are
      rejected with 422. The 2xx responses include the interval (the
      `:session_expires` of the service, or the requested one if lower),
      with the UAS as refresher unless the request asks for one.
    * Proxies lower the interval of the requests to their `:session_expires`,
      and add it to the responses if the UAS does not support timers.

  When the session is established, the refresher gets
  `sip_dialog_update({:invite_refresh, local_sdp}, dialog, call)` at half
  the interval, and should refresh it (for example with
  `Caracola.UAC.refresh/2` or an UPDATE). If it is not refreshed, the other
  party sends a BYE before the interval ends.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.Dialog

  @doc "Returns the session interval of a dialog (secs), or `nil` without session timer."
  @spec session_expires(Dialog.handle()) :: {:ok, pos_integer() | nil} | {:error, term()}
  def session_expires(dialog) do
    with {:ok, %Dialog{meta: meta}} <- Dialog.get(dialog), do: {:ok, meta[:session_expires]}
  end

  @doc """
  Returns the time to the next refresh notification (msecs), `:expired` if
  it was already sent, or `nil` if we are not the refresher.
  """
  @spec session_refresh(Dialog.handle()) ::
          {:ok, non_neg_integer() | :expired | nil} | {:error, term()}
  def session_refresh(dialog) do
    with {:ok, %Dialog{meta: meta}} <- Dialog.get(dialog) do
      case meta[:refresh_timer] do
        {_, ref} -> {:ok, :erlang.read_timer(ref) || :expired}
        other -> {:ok, other}
      end
    end
  end

  @impl true
  def plugin_config(_srv_id, config),
    do: {:ok, Caracola.Config.add_values(config, :supported, ["timer"])}
end
