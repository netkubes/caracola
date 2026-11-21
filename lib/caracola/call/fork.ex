defmodule Caracola.Call.Fork do
  @moduledoc false
  # Stateful proxy (RFC 3261 §16.5–16.7): the request of a server
  # transaction is sent to groups of destinations, one group after another,
  # all the destinations of a group in parallel, and the best response is
  # sent back. Port of NkSIP's nksip_call_fork.
  #
  # Provisional and 2xx responses are forwarded at once. A 2xx or 6xx
  # response cancels the pending INVITE branches and stops the search.

  require Logger

  alias Caracola.{Call, Message, Reply, URI, Util}
  alias Caracola.Call.{Proxy, SessionTimer, Trans, UAC, UAS}

  @type t :: %__MODULE__{
          id: pos_integer(),
          method: Message.method(),
          request: Message.t(),
          opts: list(),
          uri_set: [[URI.t()]],
          uacs: [pos_integer()],
          pending: [pos_integer()],
          responses: [Message.t()],
          final: nil | :"2xx" | :"6xx"
        }

  defstruct [
    :id,
    :method,
    :request,
    :final,
    opts: [],
    uri_set: [],
    uacs: [],
    pending: [],
    responses: []
  ]

  @doc false
  # Starts a fork for a server transaction. `req` is the request to proxy.
  def start(%Trans{id: id, method: method}, %Message{} = req, uri_set, opts, %Call{} = call) do
    fork = %__MODULE__{id: id, method: method, request: req, opts: opts, uri_set: uri_set}
    next(fork, put(call, fork))
  end

  @doc false
  # CANCEL received for the request: no more destinations, pending INVITEs
  # are cancelled
  def cancel(id, %Call{} = call) do
    case Map.fetch(call.forks, id) do
      {:ok, %__MODULE__{method: :invite} = fork} ->
        fork = %{fork | uri_set: []}
        cancel_all(fork, nil, put(call, fork))

      {:ok, fork} ->
        put(call, %{fork | uri_set: []})

      :error ->
        call
    end
  end

  defp next(%__MODULE__{pending: []} = fork, call) do
    case fork do
      %{final: final} when final != nil ->
        delete(fork, call)

      %{uri_set: [], method: :ack} ->
        delete(fork, call)

      %{uri_set: []} ->
        call = send_reply(best_response(fork, call), fork, call)
        delete(fork, call)

      %{uri_set: [group | rest]} ->
        launch(group, %{fork | uri_set: rest}, call)
    end
  end

  defp next(_fork, call), do: call

  # All the transactions of the group are registered as pending before
  # sending, as a request can get a (local) response while being sent
  defp launch(uris, fork, call) do
    {ids, call} = Enum.map_reduce(uris, call, fn _uri, call -> Call.new_trans_id(call) end)
    pending = if fork.method == :ack, do: fork.pending, else: fork.pending ++ ids
    fork = %{fork | uacs: fork.uacs ++ ids, pending: pending}

    call =
      ids
      |> Enum.zip(uris)
      |> Enum.reduce(put(call, fork), fn {uac_id, uri}, call ->
        send_uac(fork.id, uac_id, uri, call)
      end)

    case Map.fetch(call.forks, fork.id) do
      {:ok, %__MODULE__{pending: []} = fork} -> next(fork, call)
      _ -> call
    end
  end

  defp send_uac(id, uac_id, uri, call) do
    case Map.fetch(call.forks, id) do
      {:ok, fork} ->
        case prepare(fork, uri, call) do
          {:ok, req, send_opts} ->
            UAC.send_proxy(uac_id, req, [:no_dialog | send_opts], id, call)

          {:error, error} ->
            Logger.warning("invalid fork options #{inspect(fork.opts)}: #{inspect(error)}")
            {resp, _} = Reply.make!(fork.request, {:internal_error, "Invalid Fork Options"})
            response(id, uac_id, resp, call)
        end

      :error ->
        call
    end
  end

  defp prepare(fork, uri, call) do
    with {:ok, req, send_opts} <- Proxy.prepare(fork.request, uri, fork.opts, call) do
      if SessionTimer.enabled?(call.config),
        do: {:ok, SessionTimer.proxy_request(req, call.config), send_opts},
        else: {:ok, req, send_opts}
    end
  end

  @doc false
  # A response (received or generated) for one of the requests sent
  def response(_id, _uac_id, %Message{class: {:resp, code, _}}, call) when code < 101, do: call

  def response(id, uac_id, %Message{class: {:resp, code, _}} = resp, call) do
    case Map.fetch(call.forks, id) do
      {:ok, fork} ->
        cond do
          uac_id in fork.pending -> waiting(code, resp, uac_id, fork, call)
          # Another 2xx, from a different destination
          uac_id in fork.uacs and code in 200..299 -> send_reply(resp, fork, call)
          true -> call
        end

      :error ->
        call
    end
  end

  defp waiting(code, resp, _uac_id, fork, call) when code < 200 do
    if fork.final == nil, do: send_reply(resp, fork, call), else: call
  end

  defp waiting(code, resp, uac_id, fork, call) when code < 300 do
    fork = %{fork | pending: fork.pending -- [uac_id], uri_set: []}
    call = cancel_all(fork, "SIP;cause=200;text=\"Call completed elsewhere\"", call)
    fork = %{fork | final: fork.final || :"2xx"}
    call = send_reply(resp, fork, put(call, fork))
    next(fork, call)
  end

  defp waiting(code, resp, uac_id, fork, call) when code < 400 do
    fork = %{fork | pending: fork.pending -- [uac_id]}

    case redirect(fork, resp) do
      [_ | _] = contacts ->
        launch(contacts, fork, put(call, fork))

      [] ->
        fork = %{fork | responses: [resp | fork.responses]}
        next(fork, put(call, fork))
    end
  end

  defp waiting(code, resp, uac_id, fork, call) when code < 600 do
    fork = %{fork | pending: fork.pending -- [uac_id], responses: [resp | fork.responses]}
    next(fork, put(call, fork))
  end

  defp waiting(code, resp, uac_id, fork, call) do
    fork = %{fork | pending: fork.pending -- [uac_id], uri_set: []}
    call = cancel_all(fork, "SIP;cause=#{code}", call)

    if fork.final == nil do
      fork = %{fork | final: :"6xx"}
      call = send_reply(resp, fork, put(call, fork))
      next(fork, call)
    else
      next(fork, put(call, fork))
    end
  end

  # With follow_redirects, the Contacts of 3xx responses are new destinations
  defp redirect(%__MODULE__{final: nil, opts: opts, request: req}, %Message{contacts: contacts}) do
    cond do
      :follow_redirects not in opts -> []
      req.ruri.scheme == :sips -> for %URI{scheme: :sips} = uri <- contacts, do: plain(uri)
      true -> Enum.map(contacts, &plain/1)
    end
  end

  defp redirect(_fork, _resp), do: []

  defp plain(uri), do: %{uri | disp: nil, ext_params: [], ext_headers: []}

  ## ===================================================================
  ## Internal
  ## ===================================================================

  # The response goes back with the Vias and transport of the request
  defp send_reply(resp, fork, call) do
    case Map.fetch(call.trans, fork.id) do
      {:ok, %Trans{class: :uas, request: req} = uas} ->
        resp = %{resp | id: Util.uid(), vias: req.vias, port: req.port}
        UAS.do_reply({resp, []}, uas, call)

      _ ->
        call
    end
  end

  # RFC 3261 §16.7: 401 and 407 (with all the challenges) are preferred,
  # 6xx win, and 503 becomes 500
  defp best_response(%__MODULE__{responses: []} = fork, call),
    do: elem(Reply.make!(fork.request, :temporarily_unavailable, call.config), 0)

  defp best_response(%__MODULE__{responses: responses}, _call) do
    case Enum.min_by(responses, &rank/1) do
      %Message{class: {:resp, code, _}} = best when code in [401, 407] ->
        challenges =
          for %Message{class: {:resp, code, _}} = resp <- responses,
              code in [401, 407],
              {name, _} = header <- resp.headers,
              name in ["www-authenticate", "proxy-authenticate"],
              do: header

        others =
          Enum.reject(best.headers, &(elem(&1, 0) in ["www-authenticate", "proxy-authenticate"]))

        %{best | headers: others ++ challenges}

      %Message{class: {:resp, 503, _}} = best ->
        %{best | class: {:resp, 500, ""}}

      best ->
        best
    end
  end

  defp rank(%Message{class: {:resp, code, _}}) do
    cond do
      code in [401, 407] -> 3999
      code in [415, 420, 484] -> 4000
      code == 503 -> 5000
      code >= 600 -> code
      true -> 10 * code
    end
  end

  defp cancel_all(%__MODULE__{method: :invite, pending: pending}, reason, call) do
    opts = if reason, do: [reason: reason], else: []

    Enum.reduce(pending, call, fn uac_id, call ->
      case Map.fetch(call.trans, uac_id) do
        {:ok, %Trans{class: :uac} = uac} -> UAC.cancel(uac, opts, call)
        _ -> call
      end
    end)
  end

  defp cancel_all(_fork, _reason, call), do: call

  defp put(call, fork), do: %{call | forks: Map.put(call.forks, fork.id, fork)}

  defp delete(fork, call), do: %{call | forks: Map.delete(call.forks, fork.id)}
end
