defmodule Caracola.OverloadControl do
  @moduledoc """
  SIP overload control (RFC 7339) with the loss-based algorithm: an
  overloaded server tells its clients, in the Via of its responses, the
  percentage of requests they should stop sending it, and the clients do.

  ```
  defmodule MyProxy do
    use Malla.Service,
      plugins: [Caracola.OverloadControl],
      sip: [listen: "sip:all:5060", max_calls: 10_000],
      overload_control: [start: 0.8]
  end
  ```

  ## As server

  Requests whose top Via has the `oc` parameter come from clients
  supporting overload control. Their responses get, in that Via, the
  current reduction (`oc`, a percentage, 0 when not overloaded),
  `oc-algo="loss"`, `oc-validity` (`:validity` milliseconds) and an
  increasing `oc-seq`.

  The reduction is the highest of:

    * the one set with `set_loss/3`, for example from the load of the
      application;
    * the one from the number of calls of the service: from 0 when they
      are the `:start` fraction of the `max_calls` of the sip configuration
      (0.8 by default), to 100 when they reach it. `nil` disables it.

  ## As client

  Requests sent by the service (as user agent or proxy) get `oc` and
  `oc-algo="loss"` in their Via. When a response has a reduction for a
  server (identified by its IP address), that percentage of the new
  requests (without To tag, except ACK and CANCEL) sent to it during the
  validity are not sent: they fail with `{:error, :service_unavailable}`
  (see `Caracola.UAC`), and a proxy tries the next destination, as when a
  destination can not be reached (see `Caracola.Dispatcher`).

  Requests not sent emit the `[:caracola, :overload_control, :drop]`
  telemetry event, with the `:service`, the `:ip` of the server and its
  `:loss` as metadata.

  ## Configuration

  Under the `:overload_control` key:

    * `:start` - fraction of `max_calls` at which the reduction starts
      (default 0.8), `nil` to only use `set_loss/3`.
    * `:validity` - milliseconds the reduction sent to clients is valid
      (default 500).
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.{Message, Via}
  alias Caracola.Transport.Port

  @table :caracola_overload_control

  @schema NimbleOptions.new!(
            start: [type: {:or, [:float, {:in, [nil]}]}, default: 0.8],
            validity: [type: :pos_integer, default: 500]
          )

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Sets the reduction (0 to 100) the service asks its clients for, for
  `time` milliseconds (or until changed).
  """
  @spec set_loss(module(), 0..100, pos_integer() | :infinity) :: :ok
  def set_loss(service, loss, time \\ :infinity) when loss in 0..100 do
    expires = if time == :infinity, do: :infinity, else: now() + time
    :ets.insert(@table, {{:server, service}, loss, expires})
    :ok
  end

  @doc "The reduction the service asks its clients for now."
  @spec loss(module()) :: 0..100
  def loss(service) do
    now = now()

    manual =
      case :ets.lookup(@table, {:server, service}) do
        [{_, loss, expires}] when expires == :infinity or expires > now -> loss
        _ -> 0
      end

    max(manual, calls_loss(service))
  end

  @doc """
  The reduction a server (by IP address) asked the service for, if still
  valid.
  """
  @spec server_loss(module(), :inet.ip_address()) :: 0..100
  def server_loss(service, ip) do
    case :ets.lookup(@table, {:client, service, ip}) do
      [{_, loss, expires, _seq}] -> if expires > now(), do: loss, else: 0
      [] -> 0
    end
  end

  @doc "Forgets the reductions asked by servers to a service, and the one it set."
  @spec clear(module()) :: :ok
  def clear(service) do
    :ets.match_delete(@table, {{:client, service, :_}, :_, :_, :_})
    :ets.delete(@table, {:server, service})
    :ok
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <-
           NimbleOptions.validate(Keyword.get(config, :overload_control, []), @schema) do
      sip = Keyword.get(config, :sip, [])
      params = Keyword.get(sip, :via_params, []) ++ [{"oc", nil}, {"oc-algo", ~s("loss")}]
      config = Keyword.put(config, :sip, Keyword.put(sip, :via_params, Enum.uniq(params)))
      {:ok, Keyword.put(config, :overload_control, opts)}
    end
  end

  # As server: the reduction goes in the top Via, copied to the responses
  defcb caracola_received_request(%Message{vias: [via | vias]} = req, call) do
    if match?({:ok, _}, Via.get_param(via, "oc")) do
      params = Enum.reject(via.params, &String.starts_with?(elem(&1, 0), "oc"))
      config = config(call.service)

      oc = [
        {"oc", Integer.to_string(loss(call.service))},
        {"oc-algo", ~s("loss")},
        {"oc-validity", Integer.to_string(config[:validity])},
        {"oc-seq", seq()}
      ]

      {:cont, [%{req | vias: [%{via | params: params ++ oc} | vias]}, call]}
    else
      :cont
    end
  end

  def caracola_received_request(_req, _call), do: :cont

  # As client: the reductions in the responses
  defcb caracola_received_message(
          %Message{class: {:resp, _, _}, vias: [via | _], port: %Port{remote_ip: ip}} = resp
        ) do
    with {:ok, oc} when is_binary(oc) <- Via.get_param(via, "oc"),
         {loss, ""} when loss in 0..100 <- Integer.parse(oc) do
      store(resp.service, ip, loss, via)
    end

    :cont
  end

  def caracola_received_message(_msg), do: :cont

  defcb caracola_sending_request(
          %Message{class: {:req, method}, to_tag: nil, service: service},
          %Port{remote_ip: ip}
        )
        when method not in [:ack, :cancel] and ip != nil do
    loss = server_loss(service, ip)

    if loss > 0 and :rand.uniform(100) <= loss do
      :telemetry.execute([:caracola, :overload_control, :drop], %{count: 1}, %{
        service: service,
        ip: ip,
        loss: loss
      })

      {:error, :service_unavailable}
    else
      :cont
    end
  end

  def caracola_sending_request(_req, _port), do: :cont

  ## ===================================================================
  ## Internal
  ## ===================================================================

  @doc false
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  @doc false
  # Owner of the table, started by Caracola.Application
  def start_link do
    Agent.start_link(
      fn -> :ets.new(@table, [:named_table, :public, :set, write_concurrency: true]) end,
      name: __MODULE__
    )
  end

  defp config(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> Keyword.get(config, :overload_control, [])
      _ -> []
    end
  end

  defp calls_loss(service) do
    with start when is_float(start) <- config(service)[:start],
         max when is_integer(max) <- Caracola.Call.config(service)[:max_calls] do
      ratio = Caracola.Call.count(service) / max
      if ratio <= start, do: 0, else: min(100, round((ratio - start) / (1 - start) * 100))
    else
      _ -> 0
    end
  end

  # Newer values replace older ones (by oc-seq)
  defp store(service, ip, loss, via) do
    validity =
      case Via.get_param(via, "oc-validity") do
        {:ok, value} when is_binary(value) -> parse_int(value, 500)
        _ -> 500
      end

    seq =
      case Via.get_param(via, "oc-seq") do
        {:ok, value} when is_binary(value) -> parse_seq(value)
        _ -> {0, 0}
      end

    key = {:client, service, ip}

    case :ets.lookup(@table, key) do
      [{_, _, _, current}] when current > seq -> :ok
      _ -> :ets.insert(@table, {key, loss, now() + validity, seq})
    end
  end

  # "seconds.counter"
  defp seq do
    n = :ets.update_counter(@table, :seq, {2, 1, 99_999, 0}, {:seq, 0})
    "#{System.os_time(:second)}.#{n}"
  end

  defp parse_seq(value) do
    case String.split(value, ".") do
      [a, b] -> {parse_int(a, 0), parse_int(b, 0)}
      [a] -> {parse_int(a, 0), 0}
      _ -> {0, 0}
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
