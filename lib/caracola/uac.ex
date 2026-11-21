defmodule Caracola.UAC do
  @moduledoc """
  Sending requests. Equivalent to NkSIP's `nksip_uac`.

  Requests are sent from a service (which must have listeners for the
  transports used) to a URI. By default the call waits for the final
  response and returns `{:ok, code, metas}`, or `{:error, reason}` if the
  request could not be sent.

  In-dialog requests are sent passing a `t:Caracola.Dialog.handle/0`
  instead of the service and the URI: `bye(dialog)`,
  `invite(dialog, body: sdp)`... Their From, To, Call-ID, CSeq, Route and
  Contact come from the dialog. They fail with `{:error, :unknown_dialog}`
  if the dialog does not exist, or `{:error, :request_pending}` if another
  INVITE or offer is in progress.

  Responses to INVITE (101-299) always include the dialog handle as the
  first meta: `{:ok, 200, [dialog: dialog]}`, and 2xx responses to
  SUBSCRIBE and REFER the subscription handle: `[subscription: subscription]`
  (see `Caracola.Subscription`). The ACK for a 2xx response
  must be sent with `ack/2`, unless the INVITE is sent with `:auto_2xx_ack`.

  ## Options

    * `{:add | :replace | :insert, name, value}` - header manipulation, see
      `Caracola.Message.update_header/4`; `{:remove, name}` removes a header
      (`Caracola.Message.remove_header/2`).
    * `{name, value}` for `:from`, `:to`, `:contact`, `:route`,
      `:content_type`, `:require`, `:supported`, `:expires`, `:event`,
      `:reason`, `:refer_to` and `:sip_if_match` - replace the header.
    * `{:body, body}` (a binary or a `Caracola.SDP`, which also sets the
      Content-Type), `{:call_id, call_id}` and `{:cseq_num, num}`.
    * `:contact` - add a Contact with the address of the transport used
      (added automatically for INVITE, SUBSCRIBE, NOTIFY, REFER and UPDATE).
    * `:unregister` (`[:contact, expires: 0]`) and `:unregister_all`
      (`[contact: "*", expires: 0]`), for REGISTER.
    * `{:password, password}` - answer 401 and 407 challenges (a password,
      an HA1 as `{:ha1, hex}` for MD5 or `{:ha1, algorithm, hex}`,
      `{realm, password}` or a list of them), sending the request again with
      the credentials. For each realm, the challenge with the strongest
      algorithm (SHA-512-256, SHA-256, MD5) that can be answered is used.
      The `:password` of the service configuration is also used.
    * `:allow`, `:supported`, `:accept`, `:allow_event`, `:date` and
      `:user_agent` - add the header from the service configuration.
    * `{:get_meta, metas}` - values of the final response to return:
      `:reason_phrase`, `:code`, `:call_id`, `:from`, `:to`, `:from_tag`,
      `:to_tag`, `:cseq_num`, `:body`, `:contacts`, `:handle`, `:dialog`,
      `:port` (the `Caracola.Transport.Port` it came from), `:all_headers`
      or any header name.
    * `:async` - return `{:async, handle}` at once; responses go to the
      callback.
    * `{:callback, fun}` - called with `{:resp, code, resp}` for provisional
      responses (and the final one in async mode), `{:req, req}` if
      `:get_request` is used, and `{:error, reason}` in async mode.
    * `{:subscription_state, state}` - Subscription-State of a NOTIFY (see
      `t:Caracola.Subscription.state/0`).
    * `:auto_2xx_ack` - send the ACK for 2xx responses to INVITE.
    * `:no_dialog` - do not create or update dialogs with this request.
    * `:no_auto_expire` - do not CANCEL an INVITE when its Expires time
      passes.
    * `{:session_expires, secs | {secs, :uac | :uas}}` and
      `{:min_se, secs}` - session timers (with `Caracola.SessionTimers`).
    * `{:prack_callback, fun}` - body of the PRACKs (with
      `Caracola.Rel100`).
    * `{:contact_params, params}` - header params (`[{name, value | nil}]`)
      of the automatic Contact, as feature tags (`[{"+sip.src", nil}]`).
    * `{:reg_id, n}` - `reg-id` of the Contact of a REGISTER (with
      `Caracola.Outbound`).
    * `{:refer_subscription, subscription}` - report the responses to this
      request with NOTIFYs to the subscription of a REFER (see
      `Caracola.Refer`).
    * `:new_connection`, `{:tls, opts}`, `{:connect_timeout, ms}`,
      `{:idle_timeout, ms}` - transport options.
    * `{:timeout, ms}` - maximum time to wait for the result.
  """

  alias Caracola.{Call, Dialog, Message, Util}

  @typedoc "The result of sending a request."
  @type result :: {:ok, 100..699, list()} | {:async, handle()} | :ok | {:error, term()}

  @typedoc "Identifies a request sent with `:async`, to cancel it."
  @type handle :: {module(), String.t(), String.t()}

  @typedoc """
  A service and a URI, or a dialog or subscription (and then the options go
  second).
  """
  @type target :: module() | Dialog.handle() | Caracola.Subscription.handle()

  @doc """
  Sends a request with any method (an atom like `:options` or a string),
  as `request(service, method, uri, opts)` or, inside a dialog,
  `request(dialog, method, opts)`.
  """
  @spec request(target(), Message.method(), String.t() | Caracola.URI.t() | list(), list()) ::
          result()
  def request(target, method, uri_or_opts \\ [], opts \\ [])

  def request({:subscription, service, call_id, dialog_id, id}, method, opts, [])
      when is_list(opts),
      do: request({:dialog, service, call_id, dialog_id}, method, [{:subscription, id} | opts])

  def request({:dialog, service, call_id, dialog_id}, method, opts, []) when is_list(opts) do
    Call.work(
      service,
      call_id,
      {:send_dialog, dialog_id, to_method(method), opts},
      Util.opt(opts, :timeout, :infinity)
    )
  end

  def request(service, method, uri, opts) when is_atom(service) do
    call_id = Util.opt(opts, :call_id) || Util.uid()

    Call.work(
      service,
      call_id,
      {:send, to_method(method), uri, opts},
      Util.opt(opts, :timeout, :infinity)
    )
  end

  defp to_method(method) when is_binary(method), do: Message.to_method(method)
  defp to_method(method), do: method

  for method <- [
        :options,
        :invite,
        :bye,
        :register,
        :message,
        :info,
        :subscribe,
        :notify,
        :refer,
        :publish,
        :update
      ] do
    @doc "Sends a #{method |> Atom.to_string() |> String.upcase()} request. See `request/4`."
    @spec unquote(method)(target(), String.t() | Caracola.URI.t() | list(), list()) :: result()
    def unquote(method)(target, uri_or_opts \\ [], opts \\ []),
      do: request(target, unquote(method), uri_or_opts, opts)
  end

  @doc """
  Refreshes the session of a dialog with a re-INVITE carrying the current
  local SDP with a new version (or `{:body, sdp}`). `:hold`, `:inactive`
  and `:active` change the direction of the medias.
  """
  @spec refresh(Dialog.handle(), list()) :: result()
  def refresh({:dialog, _, _, _} = dialog, opts \\ []) do
    direction = Enum.find([:hold, :inactive, :active], &(&1 in opts))
    body = refresh_body(Util.opt(opts, :body) || local_sdp(dialog), direction)
    opts = Enum.reject(opts, &(&1 in [:hold, :inactive, :active] or match?({:body, _}, &1)))
    invite(dialog, if(body, do: [{:body, body} | opts], else: opts))
  end

  defp local_sdp(dialog) do
    case Dialog.get(dialog) do
      {:ok, %Dialog{invite: %{local_sdp: %Caracola.SDP{} = sdp}}} -> sdp
      _ -> nil
    end
  end

  defp refresh_body(%Caracola.SDP{} = sdp, nil), do: Caracola.SDP.increment(sdp)
  defp refresh_body(%Caracola.SDP{} = sdp, :hold), do: Caracola.SDP.update(sdp, :sendonly)
  defp refresh_body(%Caracola.SDP{} = sdp, :inactive), do: Caracola.SDP.update(sdp, :inactive)
  defp refresh_body(%Caracola.SDP{} = sdp, :active), do: Caracola.SDP.update(sdp, :sendrecv)
  defp refresh_body(body, _direction), do: body

  @doc """
  Sends the ACK for a 2xx response to an INVITE in a dialog. Returns `:ok`
  once sent.
  """
  @spec ack(Dialog.handle(), list()) :: :ok | {:error, term()}
  def ack({:dialog, _, _, _} = dialog, opts \\ []), do: request(dialog, :ack, opts)

  @doc """
  Cancels an INVITE sent with `:async`. The CANCEL is sent once a
  provisional response has been received.
  """
  @spec cancel(handle(), list()) :: :ok | {:error, term()}
  def cancel({service, call_id, id}, opts \\ []),
    do: Call.work(service, call_id, {:cancel, id, opts})
end
