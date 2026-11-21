defmodule Caracola.Call.SessionTimer do
  @moduledoc false
  # Session timers (RFC 4028) for INVITE and UPDATE, active when the
  # service supports "timer" (see Caracola.SessionTimers). Port of NkSIP's
  # nksip_timers_lib.
  #
  # The session interval is negotiated with the Session-Expires and Min-SE
  # headers (422 if it is too small). The refresher must refresh the session
  # (re-INVITE or UPDATE) before it expires; it gets a notification at half
  # the interval. The other party sends a BYE if it is not refreshed.

  alias Caracola.{Dialog, Message}

  @max_422_tries 5

  @doc false
  def enabled?(config), do: "timer" in (config[:supported] || [])

  @doc false
  # Session-Expires of a message: `{:ok, interval, refresher}`, `nil` or
  # `:invalid`
  def parse(%Message{} = msg) do
    with [value] <- Message.header(msg, "session-expires"),
         {:ok, [{se, params}]} <- Caracola.Tokens.parse(value),
         {se, ""} when se > 0 <- Integer.parse(se) do
      refresher =
        case List.keyfind(params, "refresher", 0) do
          {_, "uac"} -> :uac
          {_, "uas"} -> :uas
          _ -> nil
        end

      {:ok, se, refresher}
    else
      [] -> nil
      _ -> :invalid
    end
  end

  defp min_se(%Message{} = msg) do
    with [value] <- Message.header(msg, "min-se"),
         {min_se, ""} <- Integer.parse(String.trim(value)) do
      min_se
    else
      _ -> nil
    end
  end

  @doc false
  # Session-Expires header value
  def header(se, nil), do: se

  def header(se, refresher),
    do: {Integer.to_string(se), [{"refresher", Atom.to_string(refresher)}]}

  defp timer?(%Message{} = msg), do: "timer" in msg.supported or "timer" in msg.require

  # Interval offered to the other party: our configured one (or the
  # requested one if lower), not below the Min-SE of the request
  defp interval(req, req_se, config) do
    min_se = min_se(req) || 90
    default = config[:session_expires] || 1800

    case req_se do
      {:ok, se, _} -> max(min_se, min(se, default))
      _ -> max(min_se, default)
    end
  end

  ## ===================================================================
  ## UAC
  ## ===================================================================

  @doc false
  # Options for an in-dialog INVITE or UPDATE: the current interval, keeping
  # the roles, and our Min-SE if a 422 was received
  def dialog_opts(method, %Dialog{meta: meta}) when method in [:invite, :update] do
    case meta do
      %{session_expires: se} when is_integer(se) ->
        min_se = Map.get(meta, :min_se)
        refresher = if Map.get(meta, :refresh_timer), do: :uac, else: :uas
        se = if min_se, do: max(se, min_se), else: se
        [session_expires: {se, refresher}] ++ if(min_se, do: [min_se: min_se], else: [])

      _ ->
        []
    end
  end

  def dialog_opts(_method, _dialog), do: []

  @doc false
  # 422 response: the request is sent again with the Min-SE of the response.
  # Returns the new request and the Min-SE to remember in the dialog.
  def retry_422(%Message{class: {:req, method}} = req, resp, iter, current_min_se, config)
      when method in [:invite, :update] and iter < @max_422_tries do
    with resp_min_se when is_integer(resp_min_se) <- min_se(resp),
         {:ok, se, refresher} <- parse(req) do
      min_se = max(current_min_se || config[:min_se] || 90, resp_min_se)

      {:ok, req} =
        Message.update_header(
          req,
          :replace,
          "session-expires",
          header(max(se, min_se), refresher)
        )

      {:ok, req} = Message.update_header(req, :replace, "min-se", min_se)
      {:ok, req, min_se}
    else
      _ -> :error
    end
  end

  def retry_422(_req, _resp, _iter, _current_min_se, _config), do: :error

  ## ===================================================================
  ## UAS
  ## ===================================================================

  @doc false
  # Checks the interval of an INVITE or UPDATE: 422 if it is too small (or
  # only raises the Min-SE if the request does not support timers, as a
  # proxy)
  def check(%Message{class: {:req, method}} = req, config) when method in [:invite, :update] do
    min_se = config[:min_se] || 90

    case parse(req) do
      nil ->
        :ok

      :invalid ->
        {:reply, {:invalid_request, "Invalid Session-Expires"}}

      {:ok, se, _} when se < min_se ->
        if timer?(req) do
          {:reply, {:session_too_small, min_se}, min_se}
        else
          {:ok, req} = Message.update_header(req, :replace, "min-se", min_se)
          {:update, req, min_se}
        end

      {:ok, _, _} ->
        :ok
    end
  end

  def check(_req, _config), do: :ok

  @doc false
  # The 2xx response to an INVITE or UPDATE gets the interval (and Require:
  # timer if the request supports it). The refresher is the one requested,
  # or the UAS.
  def uas_response(
        %Message{} = req,
        %Message{class: {:resp, code, _}, cseq: {_, method}} = resp,
        config
      )
      when code in 200..299 and method in [:invite, :update] do
    if parse(resp) == nil and "timer" in resp.supported do
      req_se = if timer?(req), do: parse(req)

      refresher =
        case req_se do
          {:ok, _, refresher} when refresher != nil -> refresher
          _ -> :uas
        end

      value = header(interval(req, req_se, config), refresher)
      {:ok, resp} = Message.update_header(resp, :replace, "session-expires", value)

      if timer?(req) and "timer" not in resp.require,
        do: %{resp | require: ["timer" | resp.require]},
        else: resp
    else
      resp
    end
  end

  def uas_response(_req, resp, _config), do: resp

  ## ===================================================================
  ## Proxy
  ## ===================================================================

  @doc false
  # A proxied INVITE or UPDATE gets our interval if lower
  def proxy_request(%Message{class: {:req, method}} = req, config)
      when method in [:invite, :update] do
    se = interval(req, parse(req), config)

    case parse(req) do
      {:ok, ^se, _} ->
        req

      _ ->
        {:ok, req} = Message.update_header(req, :replace, "session-expires", se)
        req
    end
  end

  def proxy_request(req, _config), do: req

  @doc false
  # If the UAS does not support timers but the UAC does, the 2xx gets the
  # interval with the UAC as refresher
  def proxy_response(
        %Message{} = req,
        %Message{class: {:resp, code, _}, cseq: {_, method}} = resp
      )
      when code in 200..299 and method in [:invite, :update] do
    with nil <- parse(resp),
         {:ok, se, _} <- parse(req),
         true <- timer?(req) do
      {:ok, resp} = Message.update_header(resp, :replace, "session-expires", header(se, :uac))
      %{resp | require: Enum.uniq(["timer" | resp.require])}
    else
      _ -> resp
    end
  end

  def proxy_response(_req, resp), do: resp

  ## ===================================================================
  ## Dialogs
  ## ===================================================================

  @doc false
  # The role of a party after a 2xx response to an INVITE or UPDATE it sent
  # (class :uac) or received (class :uas): `{:refresher | :refreshed, interval}`,
  # or `:none` if no session timer was negotiated
  def role(class, %Message{} = req, %Message{} = resp) do
    case {parse(resp), parse(req)} do
      {{:ok, se, refresher}, _} when refresher != nil -> party(class, se, refresher)
      {_, {:ok, se, refresher}} when refresher != nil -> party(class, se, refresher)
      _ -> :none
    end
  end

  defp party(class, se, class), do: {:refresher, se}
  defp party(_class, se, _refresher), do: {:refreshed, se}
end
