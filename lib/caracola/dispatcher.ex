defmodule Caracola.Dispatcher do
  @moduledoc """
  Groups of destinations (gateways, media servers, other proxies) for a
  proxy, with load balancing, health checks and failover.

  ```
  defmodule MyProxy do
    use Malla.Service,
      plugins: [Caracola.Dispatcher],
      sip: [listen: "sip:all:5060"],
      dispatcher: [
        groups: [
          gateways: [
            destinations: ["sip:10.0.0.1", {"sip:10.0.0.2;transport=tcp", 2}],
            strategy: :weighted
          ]
        ]
      ]

    defcb sip_route(_scheme, _user, _domain, req, call),
      do: Caracola.Dispatcher.route(:gateways, req, call, [:record_route])
  end
  ```

  `route/4` proxies a request to the destinations of a group, in the order
  given by its strategy, one after another (serial forking, see
  [Proxies](07-proxy.md)): if a destination fails, the next one is tried.
  `select/3` returns that order, to build other routes.

  ## Strategies

    * `:priority` (default) - in the configured order: the first
      destination gets all the requests while it is up.
    * `:round_robin` - each request starts with the next destination.
    * `:weighted` - random, each destination proportionally to its weight
      (1 by default).
    * `:hash` - by a key (the Call-ID in `route/4`): requests with the same
      key go to the same destination while it is up, and the requests of a
      destination that goes down are spread among the others (rendezvous
      hashing).

  ## Health checks

  Every destination is sent an OPTIONS request periodically. Any response
  but a 408 or 503 means it is up; after a number of failures in a row it
  is marked as down, and not used until a check succeeds again. Destinations
  start as up. Changes emit the `[:caracola, :dispatcher, :status]`
  telemetry event, with the `:service`, `:uri` (a string) and `:status`
  (`:up` or `:down`) as metadata. `set_status/3` changes the status by
  hand, for example after a failure seen by the application, until the
  next check.

  ## Configuration

  Under the `:dispatcher` key:

    * `:groups` - keyword list of groups, each with:
      * `:destinations` - list of URIs, or `{uri, weight}`.
      * `:strategy` - `:priority`, `:round_robin`, `:weighted` or `:hash`.
    * `:probe` - health checks, `false` to disable them:
      * `:interval` - milliseconds between checks (default 30000).
      * `:timeout` - milliseconds to wait for the response (default 5000).
      * `:failures` - failures in a row to mark a destination as down
        (default 2).
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.Dispatcher.Server
  alias Caracola.{Message, URI}

  @typedoc "How a group chooses a destination."
  @type strategy :: :priority | :round_robin | :weighted | :hash
  @typedoc "A destination of a group: its URI, its weight and whether it is up or down."
  @type destination :: %{uri: URI.t(), weight: pos_integer(), status: :up | :down}

  @group_schema NimbleOptions.new!(
                  destinations: [type: {:list, :any}, required: true],
                  strategy: [
                    type: {:in, [:priority, :round_robin, :weighted, :hash]},
                    default: :priority
                  ]
                )

  @probe_schema NimbleOptions.new!(
                  interval: [type: :pos_integer, default: 30_000],
                  timeout: [type: :pos_integer, default: 5_000],
                  failures: [type: :pos_integer, default: 2]
                )

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  A `sip_route/5` result proxying a request to the destinations of a group
  (with `proxy_opts`, see [Proxies](07-proxy.md)), tried one after
  another, or a 503 if none is up.

  The Request-URI is sent to each destination with its user, if the
  destination URI has none.
  """
  @spec route(atom(), Message.t(), Caracola.Call.t(), list()) ::
          {:proxy, [[URI.t()]], list()} | {:reply, :service_unavailable}
  def route(group, %Message{} = req, call, proxy_opts \\ []) do
    case select(call.service, group, key: req.call_id) do
      [] -> {:reply, :service_unavailable}
      uris -> {:proxy, for(uri <- uris, do: [target(uri, req.ruri)]), proxy_opts}
    end
  end

  defp target(%URI{user: nil} = uri, %URI{user: user}), do: %{uri | user: user}
  defp target(uri, _ruri), do: uri

  @doc """
  The destinations of a group that are up, in the order of its strategy.

  Options:

    * `:key` - the key for the `:hash` strategy.
    * `:max` - maximum number of destinations.
  """
  @spec select(module(), atom(), keyword()) :: [URI.t()]
  def select(service, group, opts \\ []) do
    case groups(service)[group] do
      nil ->
        []

      %{strategy: strategy, destinations: dests} ->
        dests
        |> Enum.filter(&(Server.status(service, &1.key) == :up))
        |> order(strategy, service, group, opts)
        |> Enum.take(Keyword.get(opts, :max, length(dests)))
        |> Enum.map(& &1.uri)
    end
  end

  @doc "The destinations of a group, with their weight and status."
  @spec destinations(module(), atom()) :: [destination()]
  def destinations(service, group) do
    case groups(service)[group] do
      nil ->
        []

      %{destinations: dests} ->
        for d <- dests, do: %{uri: d.uri, weight: d.weight, status: Server.status(service, d.key)}
    end
  end

  @doc """
  Changes the status of a destination (in all its groups), until the next
  health check.
  """
  @spec set_status(module(), String.t() | URI.t(), :up | :down) :: :ok
  def set_status(service, uri, status) when status in [:up, :down],
    do: Server.set_status(service, key(uri), status)

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    opts = Keyword.get(config, :dispatcher, [])

    with {:ok, groups} <- parse_groups(Keyword.get(opts, :groups, [])),
         {:ok, probe} <- parse_probe(Keyword.get(opts, :probe, [])) do
      {:ok, Keyword.put(config, :dispatcher, groups: groups, probe: probe)}
    end
  end

  @impl true
  def plugin_start(srv_id, config) do
    dispatcher = config[:dispatcher]
    keys = for {_, g} <- dispatcher[:groups], d <- g.destinations, uniq: true, do: d.key
    {:ok, children: [{Server, {srv_id, keys, dispatcher[:probe]}}]}
  end

  @impl true
  def plugin_updated(_srv_id, old_config, new_config) do
    if old_config[:dispatcher] == new_config[:dispatcher],
      do: :ok,
      else: {:ok, restart: true}
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp groups(service) do
    case Malla.Service.get_config(service) do
      config when is_list(config) -> get_in(config, [:dispatcher, :groups]) || %{}
      _ -> %{}
    end
  end

  defp order(dests, :priority, _service, _group, _opts), do: dests

  defp order([], :round_robin, _service, _group, _opts), do: []

  defp order(dests, :round_robin, service, group, _opts) do
    {first, last} = Enum.split(dests, rem(Server.next(service, group), length(dests)))
    last ++ first
  end

  # Efraimidis-Spirakis: sorted by u^(1/weight), u random in (0, 1)
  defp order(dests, :weighted, _service, _group, _opts),
    do: Enum.sort_by(dests, &(:rand.uniform() ** (1 / &1.weight)), :desc)

  defp order(dests, :hash, _service, _group, opts) do
    key = Keyword.get(opts, :key)
    Enum.sort_by(dests, &:erlang.phash2({key, &1.key}), :desc)
  end

  defp parse_groups(groups) do
    Enum.reduce_while(groups, {:ok, %{}}, fn {name, opts}, {:ok, acc} ->
      with {:ok, opts} <- NimbleOptions.validate(opts, @group_schema),
           {:ok, dests} <- parse_destinations(opts[:destinations]) do
        {:cont, {:ok, Map.put(acc, name, %{strategy: opts[:strategy], destinations: dests})}}
      else
        {:error, %NimbleOptions.ValidationError{} = error} ->
          {:halt, {:error, {:invalid_dispatcher_group, name, Exception.message(error)}}}

        {:error, error} ->
          {:halt, {:error, {:invalid_dispatcher_group, name, error}}}
      end
    end)
  end

  defp parse_destinations(list) do
    Enum.reduce_while(list, {:ok, []}, fn dest, {:ok, acc} ->
      {uri, weight} = if is_tuple(dest), do: dest, else: {dest, 1}

      case is_binary(uri) and is_integer(weight) and weight > 0 and parse_uri(uri) do
        {:ok, %URI{} = parsed} ->
          {:cont, {:ok, acc ++ [%{uri: parsed, key: key(parsed), weight: weight}]}}

        _ ->
          {:halt, {:error, {:invalid_destination, dest}}}
      end
    end)
  end

  # Parameters belong to the URI, as in "sip:10.0.0.1;transport=tcp"
  defp parse_uri(uri) do
    if String.contains?(uri, "<"), do: URI.parse_one(uri), else: URI.parse_one("<" <> uri <> ">")
  end

  defp parse_probe(false), do: {:ok, false}

  defp parse_probe(opts) do
    case NimbleOptions.validate(opts, @probe_schema) do
      {:ok, opts} -> {:ok, opts}
      {:error, error} -> {:error, {:invalid_dispatcher_probe, Exception.message(error)}}
    end
  end

  defp key(%URI{} = uri), do: to_string(uri)
  defp key(uri) when is_binary(uri), do: uri |> parse_uri() |> elem(1) |> key()
end
