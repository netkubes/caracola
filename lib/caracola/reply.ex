defmodule Caracola.Reply do
  @moduledoc """
  Generation of responses from "sip replies". Port of NkSIP's `nksip_reply`
  and `nksip_call_uas_make`.

  A sip reply is a status code, `{code, opts}`, or one of these shortcuts:

  | Reply | Code |
  |---|---|
  | `:ringing`, `:session_progress` | 180, 183 |
  | `:rel_ringing`, `{:rel_ringing, body}` | 180, reliable (see `Caracola.Rel100`) |
  | `:rel_session_progress`, `{:rel_session_progress, body}` | 183, reliable |
  | `:ok`, `{:ok, opts}`, `{:answer, body}` | 200 |
  | `:accepted` | 202 |
  | `{:redirect, contacts}` | 300 |
  | `{:redirect_permanent, contact}`, `{:redirect_temporary, contact}` | 301, 302 |
  | `:invalid_request`, `{:invalid_request, phrase}` | 400 |
  | `:forbidden`, `{:forbidden, phrase}` | 403 |
  | `:not_found`, `{:not_found, phrase}` | 404 |
  | `{:method_not_allowed, allow}` | 405 |
  | `:timeout`, `{:timeout, phrase}` | 408 |
  | `:conditional_request_failed` | 412 |
  | `:request_too_large` | 413 |
  | `{:unsupported_media_type, accept}`, `{:unsupported_media_encoding, enc}` | 415 |
  | `:unsupported_uri_scheme` | 416 |
  | `{:bad_extension, unsupported}` | 420 |
  | `{:extension_required, require}` | 421 |
  | `{:session_too_small, min_se}` | 422 |
  | `{:interval_too_brief, min_expires}` | 423 |
  | `:flow_failed` | 430 |
  | `:first_hop_lacks_outbound` | 439 |
  | `:temporarily_unavailable` | 480 |
  | `:unknown_dialog`, `:no_transaction` | 481 |
  | `:loop_detected` | 482 |
  | `:too_many_hops` | 483 |
  | `:ambiguous` | 485 |
  | `:busy` | 486 |
  | `:request_terminated` | 487 |
  | `{:not_acceptable, warning}` | 488 |
  | `:bad_event` | 489 |
  | `:request_pending` | 491 |
  | `:internal_error`, `{:internal_error, phrase}` | 500 |
  | `:service_unavailable`, `{:service_unavailable, phrase}` | 503 |
  | `:busy_everywhere` | 600 |
  | `:decline` | 603 |

  In `sip_authorize/3`, `:authenticate` and `:proxy_authenticate` (or
  `{:authenticate, realm}` and `{:proxy_authenticate, realm}`) reply with
  a 401 or 407 digest challenge.

  Response options:

    * `{:add | :replace | :insert, name, value}` - header manipulation, see
      `Caracola.Message.update_header/4`.
    * `{name, value}` for `:from`, `:to`, `:contact`, `:route`,
      `:content_type`, `:require`, `:supported`, `:expires`, `:event` and
      `:reason` - replace the header.
    * `{:body, body}` and `{:reason_phrase, phrase}`.
    * `{:to_tag, tag}` - use this To tag.
    * `:contact` - add a Contact with the address of the transport used.
    * `:allow`, `:supported`, `:accept`, `:allow_event`, `:date`,
      `:user_agent`, `:timestamp` - add the corresponding header, from the
      service configuration or the request.
  """

  alias Caracola.{Message, Util}

  @typedoc "A reply for a request: a status code, `{code, opts}` or a named reply as `:ok` or `:busy`."
  @type sipreply ::
          non_neg_integer() | {non_neg_integer(), keyword() | list()} | atom() | {atom(), term()}

  # Options handled when sending the response
  @send_opts [:contact, :no_dialog, :secure]

  @doc """
  Generates a response for `req`. Returns the response and the options to
  use when sending it.
  """
  @spec make(Message.t(), sipreply(), keyword()) :: {:ok, Message.t(), list()} | {:error, term()}
  def make(%Message{class: {:req, _}} = req, sipreply, config \\ []) do
    case parse(sipreply) do
      {:ok, code, opts} -> build(req, code, post(req, code, opts, config), config)
      :error -> {:error, {:invalid_reply, sipreply}}
    end
  end

  @doc """
  Like `make/3`, but invalid replies or options generate a `500` response,
  as NkSIP does for user replies.
  """
  @spec make!(Message.t(), sipreply(), keyword()) :: {Message.t(), list()}
  def make!(req, sipreply, config \\ []) do
    case make(req, sipreply, config) do
      {:ok, resp, send_opts} ->
        {resp, send_opts}

      {:error, _} ->
        {:ok, resp, send_opts} =
          make(req, {500, [reason_phrase: "Invalid Service Response"]}, config)

        {resp, send_opts}
    end
  end

  @doc """
  Converts a sip reply into a code and options.

      iex> Caracola.Reply.parse(:busy)
      {:ok, 486, []}
      iex> Caracola.Reply.parse({:bad_extension, "a, b"})
      {:ok, 420, [{:replace, "unsupported", "a, b"}]}
      iex> Caracola.Reply.parse(:unknown)
      :error
  """
  @spec parse(sipreply()) :: {:ok, 100..699, list()} | :error
  def parse(code) when is_integer(code) and code in 100..699, do: {:ok, code, []}

  def parse({code, opts}) when is_integer(code) and code in 100..699 and is_list(opts),
    do: {:ok, code, opts}

  def parse(reply) do
    case shortcut(reply) do
      {code, opts} -> {:ok, code, opts}
      :error -> :error
    end
  end

  @phrase_replies %{
    invalid_request: {400, [:date]},
    forbidden: {403, []},
    not_found: {404, []},
    timeout: {408, []},
    internal_error: {500, [:date]},
    service_unavailable: {503, [:date]}
  }

  defp shortcut(reply) when is_map_key(@phrase_replies, reply), do: @phrase_replies[reply]

  defp shortcut({reply, phrase}) when is_map_key(@phrase_replies, reply) and is_binary(phrase) do
    {code, opts} = @phrase_replies[reply]
    {code, [{:reason_phrase, phrase} | opts]}
  end

  defp shortcut(:ringing), do: {180, []}
  defp shortcut(:session_progress), do: {183, []}
  defp shortcut(:rel_ringing), do: {180, [:do100rel]}
  defp shortcut({:rel_ringing, body}), do: {180, [:do100rel, body: body]}
  defp shortcut(:rel_session_progress), do: {183, [:do100rel]}
  defp shortcut({:rel_session_progress, body}), do: {183, [:do100rel, body: body]}
  defp shortcut(:ok), do: {200, []}
  defp shortcut({:ok, opts}) when is_list(opts), do: {200, opts}
  defp shortcut({:answer, body}), do: {200, [body: body]}
  defp shortcut(:accepted), do: {202, []}
  defp shortcut({:redirect, contacts}), do: {300, [contact: contacts]}
  defp shortcut({:redirect_permanent, contact}), do: {301, [contact: contact]}
  defp shortcut({:redirect_temporary, contact}), do: {302, [contact: contact]}
  defp shortcut({:method_not_allowed, allow}), do: {405, [{:replace, "allow", allow}]}
  defp shortcut(:conditional_request_failed), do: {412, []}
  defp shortcut(:request_too_large), do: {413, []}
  defp shortcut({:unsupported_media_type, accept}), do: {415, [{:replace, "accept", accept}]}

  defp shortcut({:unsupported_media_encoding, enc}),
    do: {415, [{:replace, "accept-encoding", enc}]}

  defp shortcut(:unsupported_uri_scheme), do: {416, []}

  defp shortcut({:bad_extension, unsupported}),
    do: {420, [{:replace, "unsupported", unsupported}]}

  defp shortcut({:extension_required, require}), do: {421, [require: require]}

  defp shortcut({:session_too_small, min}) when is_integer(min),
    do: {422, [{:add, "min-se", min}]}

  defp shortcut({:interval_too_brief, min}) when is_integer(min),
    do: {423, [{:replace, "min-expires", min}]}

  defp shortcut(:flow_failed), do: {430, []}
  defp shortcut(:first_hop_lacks_outbound), do: {439, []}
  defp shortcut(:temporarily_unavailable), do: {480, []}
  defp shortcut(:unknown_dialog), do: {481, []}
  defp shortcut(:no_transaction), do: {481, []}
  defp shortcut(:loop_detected), do: {482, []}
  defp shortcut(:too_many_hops), do: {483, []}
  defp shortcut(:ambiguous), do: {485, []}
  defp shortcut(:busy), do: {486, []}
  defp shortcut(:request_terminated), do: {487, []}
  defp shortcut({:not_acceptable, warning}), do: {488, [{:replace, "warning", warning}]}
  defp shortcut(:bad_event), do: {489, []}
  defp shortcut(:request_pending), do: {491, []}
  defp shortcut(:busy_everywhere), do: {600, []}
  defp shortcut(:decline), do: {603, []}
  defp shortcut(_), do: :error

  @dialog_methods [:invite, :update, :subscribe, :refer]

  # Default options added depending on the method and code
  defp post(%Message{class: {:req, method}} = req, code, opts, config) do
    # The Expires of a 2xx to SUBSCRIBE is calculated in event_opts/5
    # (opts mixes flags and {key, value} pairs)
    user_opts =
      if code in 200..299 and method == :subscribe,
        do: Enum.reject(opts, &match?({:expires, _}, &1)),
        else: opts

    common_opts(code, method) ++
      route_opts(req, code, method, opts) ++
      event_opts(req, code, method, opts, config) ++
      rel_opts(req, code, method) ++
      recv_info_opts(code, method) ++ user_opts
  end

  # Provisional responses to INVITE are reliable if the request requires it
  defp rel_opts(req, code, :invite) when code in 101..199,
    do: if("100rel" in req.require, do: [:do100rel], else: [])

  defp rel_opts(_req, _code, _method), do: []

  # INFO packages (RFC 6086)
  defp recv_info_opts(code, :invite) when code in 101..299, do: [:recv_info]
  defp recv_info_opts(_code, _method), do: []

  defp common_opts(code, _method) when code <= 100, do: []

  defp common_opts(_code, method) when method in @dialog_methods,
    do: [:timestamp, :allow, :supported]

  defp common_opts(_code, _method), do: [:timestamp]

  defp route_opts(req, code, method, opts) do
    record_route =
      if code in 101..299 and method in [:invite, :notify],
        do: [{:replace, "record-route", Message.header(req, "record-route")}],
        else: []

    contact =
      if code in 101..299 and method in @dialog_methods and not contact?(opts),
        do: [:contact],
        else: []

    path =
      if code in 200..299 and method == :register,
        do: [{:replace, "path", Message.header(req, "path")}],
        else: []

    record_route ++ contact ++ path
  end

  defp event_opts(req, code, method, opts, config) do
    event =
      if method in [:subscribe, :notify, :publish] and not Util.opt?(opts, :event),
        do: [{:event, req.event}],
        else: []

    expires =
      if code in 200..299 and method == :subscribe do
        default = config[:event_expires] || 60
        [{:expires, min(req.expires || default, Util.opt(opts, :expires, default))}]
      else
        []
      end

    event ++ expires
  end

  defp contact?(opts), do: :contact in opts or Util.opt?(opts, :contact)

  defp build(req, code, opts, config) do
    %Message{vias: [top_via | _] = vias, cseq: {cseq, _}, class: {:req, method}} = req

    {vias, to, to_tag} =
      cond do
        code == 100 -> {[top_via], drop_tag(req.to), nil}
        req.to_tag != nil -> {vias, req.to, req.to_tag}
        true -> add_tag(vias, req.to, Util.opt(opts, :to_tag) || to_tag_candidate(req))
      end

    resp = %Message{
      class: {:resp, code, Util.opt(opts, :reason_phrase, "")},
      service: req.service,
      id: Util.uid(),
      port: req.port,
      vias: vias,
      from: req.from,
      from_tag: req.from_tag,
      to: to,
      to_tag: to_tag,
      call_id: req.call_id,
      cseq: {cseq, method}
    }

    apply_opts(opts, req, resp, code, config, [])
  end

  @doc false
  # A deterministic To tag, so that retransmissions get the same one
  def to_tag_candidate(%Message{vias: [via | _]}) do
    case Caracola.Via.get_param(via, "branch") do
      {:ok, branch} when is_binary(branch) -> Util.hash({Util.global_id(), branch})
      _ -> Util.uid()
    end
  end

  defp drop_tag(to), do: %{to | ext_params: Enum.reject(to.ext_params, &tag_param?/1)}

  defp add_tag(vias, to, tag),
    do:
      {vias, %{to | ext_params: Enum.reject(to.ext_params, &tag_param?/1) ++ [{"tag", tag}]}, tag}

  defp tag_param?({name, _}), do: Util.ascii_downcase(name) == "tag"

  @header_opts [
    :from,
    :to,
    :content_type,
    :require,
    :supported,
    :expires,
    :contact,
    :route,
    :reason,
    :event,
    :sip_etag
  ]

  defp apply_opts([], _req, resp, _code, _config, send_opts),
    do: {:ok, resp, Enum.reverse(send_opts)}

  defp apply_opts([opt | rest], req, resp, code, config, send_opts) do
    case apply_opt(opt, req, resp, code, config) do
      {:ok, resp} -> apply_opts(rest, req, resp, code, config, send_opts)
      {:send, opt} -> apply_opts(rest, req, resp, code, config, [opt | send_opts])
      {:error, error} -> {:error, error}
    end
  end

  defp apply_opt({op, name, value}, _req, resp, _code, _config)
       when op in [:add, :replace, :insert],
       do: Message.update_header(resp, op, name, value)

  defp apply_opt({name, value}, _req, resp, _code, _config) when name in @header_opts,
    do: Message.update_header(resp, :replace, name, value)

  defp apply_opt({:body, body}, _req, resp, _code, _config) when is_binary(body),
    do: {:ok, %{resp | body: body}}

  defp apply_opt({:body, nil}, _req, resp, _code, _config), do: {:ok, resp}

  defp apply_opt({:body, %Caracola.SDP{} = sdp}, _req, resp, _code, _config),
    do: {:ok, Caracola.SDP.put_body(resp, sdp)}

  defp apply_opt({:reason_phrase, _}, _req, resp, _code, _config), do: {:ok, resp}

  # Reliable provisional response (RFC 3262), if the request supports it
  defp apply_opt(:do100rel, %Message{class: {:req, :invite}} = req, resp, code, _config)
       when code in 101..199 do
    supported? = "100rel" in req.supported or "100rel" in req.require

    if supported? and "100rel" not in resp.require,
      do: {:ok, %{resp | require: ["100rel" | resp.require]}},
      else: {:ok, resp}
  end

  defp apply_opt(:do100rel, _req, resp, _code, _config), do: {:ok, resp}
  defp apply_opt({:to_tag, _}, _req, resp, _code, _config), do: {:ok, resp}
  defp apply_opt(opt, _req, _resp, _code, _config) when opt in @send_opts, do: {:send, opt}

  defp apply_opt(:timestamp, req, resp, _code, _config) do
    case Message.header(req, "timestamp") do
      [time] -> Message.update_header(resp, :replace, "timestamp", time)
      _ -> {:ok, resp}
    end
  end

  defp apply_opt(:allow, _req, resp, _code, config),
    do: Message.update_header(resp, :replace, "allow", Keyword.get(config, :allow, []))

  defp apply_opt(:supported, _req, resp, _code, config),
    do: Message.update_header(resp, :replace, "supported", Keyword.get(config, :supported, []))

  defp apply_opt(:accept, %Message{class: {:req, method}}, resp, _code, config) do
    accept =
      case config[:accept] do
        nil when method in [:invite, :update, :prack] -> "application/sdp"
        nil -> "*/*"
        accept -> accept
      end

    Message.update_header(resp, :replace, "accept", accept)
  end

  defp apply_opt(:recv_info, _req, resp, _code, config) do
    case Keyword.get(config, :info_packages) do
      nil -> {:ok, resp}
      packages -> Message.update_header(resp, :replace, "recv-info", Enum.join(packages, ", "))
    end
  end

  defp apply_opt(:allow_event, _req, resp, _code, config) do
    case Keyword.get(config, :events, []) do
      [] -> {:ok, resp}
      events -> Message.update_header(resp, :replace, "allow-event", events)
    end
  end

  defp apply_opt(:date, _req, resp, _code, _config),
    do: Message.update_header(resp, :replace, "date", Caracola.Date.now())

  defp apply_opt(:user_agent, _req, resp, _code, _config),
    do: Message.update_header(resp, :replace, "user-agent", "Caracola")

  defp apply_opt(opt, _req, _resp, _code, _config),
    do: {:error, {:invalid_config, if(is_tuple(opt), do: elem(opt, 0), else: opt)}}
end
