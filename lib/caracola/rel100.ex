defmodule Caracola.Rel100 do
  @moduledoc """
  Reliable provisional responses (RFC 3262, `100rel` and PRACK). Equivalent
  to NkSIP's `nksip_100rel`.

  ```
  defmodule MyUA do
    use Malla.Service, plugins: [Caracola.Rel100], sip: [listen: "sip:all:5060"]
  end
  ```

  The plugin adds `100rel` to the Supported header and PRACK to the Allow
  header. With it:

    * As UAS, provisional responses to INVITE are sent reliably (with
      `Require: 100rel` and an RSeq) when the request requires it, or with
      the `:rel_ringing`, `{:rel_ringing, body}`, `:rel_session_progress`
      and `{:rel_session_progress, body}` replies (or the `:do100rel` reply
      option) if the request supports it. They are retransmitted until
      the PRACK arrives (or 64*T1, then the request is answered with 500).
      Only one can be pending: another one fails with
      `{:error, :pending_prack}`. PRACKs reach `sip_prack/2`.
    * As UAC, reliable provisional responses are acknowledged with a PRACK
      at once. The `{:prack_callback, fun}` option of the INVITE can give
      the body of the PRACK: `fun.(remote_sdp, {:resp, code, resp})` gets
      the SDP offered by the response (or `nil`) and returns an SDP (an
      answer, or a new offer) or `nil`.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  @impl true
  def plugin_config(_srv_id, config) do
    config =
      config
      |> Caracola.Config.add_values(:allow, ["PRACK"])
      |> Caracola.Config.add_values(:supported, ["100rel"])

    {:ok, config}
  end
end
