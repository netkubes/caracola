defmodule Caracola.Refer do
  @moduledoc """
  REFER (RFC 3515, call transfer). Equivalent to NkSIP's `nksip_refer`.

  ```
  defmodule MyUA do
    use Malla.Service, plugins: [Caracola.Refer], sip: [listen: "sip:all:5060"]

    defcb sip_refer(_refer_to, _req, _call), do: true
  end
  ```

  REFER requests are sent with `Caracola.UAC.refer/3` and the
  `{:refer_to, uri}` option, out of a dialog or in one. The `:subscription`
  meta of the response is the implicit subscription, which gets NOTIFYs with
  the progress of the referred request as `message/sipfrag` bodies.

  When a REFER arrives, the plugin calls `sip_refer(refer_to, req, call)`.
  If it returns `true` the REFER is accepted (202) and an INVITE is sent to
  `refer_to` (with `:auto_2xx_ack` and Call-ID `"caracola_refer_" <>
  call_id`); each response to it is notified to the referrer, and the
  subscription is terminated with the final one. `false` (the default)
  rejects it with 403.

  The referrer is told about the subscription with
  `sip_refer_update(subscription, status, call)`, where `status` is `:init`,
  `:active`, `:middle_timer`, `{:notify, sipfrag}` for each NOTIFY or
  `:terminated`.

  Any request (not only an INVITE) can report to a REFER subscription with
  the `{:refer_subscription, handle}` option of `Caracola.UAC`.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  require Logger

  alias Caracola.{Message, Subscription, UAC, URI}

  @impl true
  def plugin_config(_srv_id, config),
    do: {:ok, Caracola.Config.add_values(config, :allow, ["REFER"])}

  ## ===================================================================
  ## Callbacks
  ## ===================================================================

  defcb sip_refer(_refer_to, _req, _call), do: false

  defcb sip_refer_update(_subscription, _status, _call), do: :ok

  defcb sip_refer(req, call), do: {:reply, process(req, call)}

  # NOTIFYs and changes of REFER subscriptions go to sip_refer_update/3
  defcb caracola_callback(:sip_notify, [req, call]) do
    if refer?(req.event) do
      update(Subscription.handle_of(req), {:notify, req.body}, call)
      {:done, {:reply, :ok}}
    else
      :cont
    end
  end

  def caracola_callback(
        :sip_dialog_update,
        [{:subscription_status, status, %Subscription{event: event} = subs}, _dialog, call]
      ) do
    if refer?(event) do
      status =
        case status do
          {:terminated, _} -> :terminated
          {:terminated, _, _} -> :terminated
          status -> status
        end

      update(Subscription.handle(subs), status, call)
    end

    :cont
  end

  def caracola_callback(_fun, _args), do: :cont

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp process(req, call) do
    with [value] <- Message.header(req, "refer-to"),
         {:ok, [refer_to]} <- URI.parse(value) do
      if call.service.sip_refer(%{refer_to | ext_params: []}, req, call) == true do
        invite(refer_to, req, call)
        :accepted
      else
        :forbidden
      end
    else
      _ -> :invalid_request
    end
  end

  defp invite(refer_to, req, call) do
    opts = [
      :async,
      :auto_2xx_ack,
      call_id: "caracola_refer_" <> call.call_id,
      refer_subscription: Subscription.handle_of(req)
    ]

    spawn(fn -> UAC.invite(call.service, refer_to, opts) end)
  end

  defp update(subs, status, call) do
    call.service.sip_refer_update(subs, status, call)
  rescue
    error -> Logger.error("error calling sip_refer_update: " <> Exception.message(error))
  end

  defp refer?({type, _params}), do: Caracola.Util.ascii_downcase(type) == "refer"
  defp refer?(_event), do: false
end
