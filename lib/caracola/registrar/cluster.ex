defmodule Caracola.Registrar.Cluster do
  @moduledoc """
  A registrar shared by the nodes of a Malla cluster: every node running
  the service has all the registrations, so any of them can find the
  contacts of a user.

  ```
  defmodule MyRegistrar do
    use Malla.Service,
      global: true,
      plugins: [Caracola.Registrar.Cluster],
      sip: [listen: "sip:all:5060"]
  end
  ```

  The service must be `global: true`, so that its nodes find each other
  (see `Malla.Node.get_nodes/1`). The plugin implements
  `sip_registrar_store/2` of `Caracola.Registrar`:

    * Reads are local.
    * Each change of the contacts of an AOR is written locally and sent to
      the other connected nodes, which apply it if they run the service and
      it is newer than the one they have
      (the last write wins, by its time). Removed AORs are kept for a
      while without contacts, so that older changes arriving later do not
      bring them back.
    * When a node starts, and every `:sync_interval` milliseconds, it
      merges the registrations of another node, so nodes that were
      disconnected (or missed changes) converge.

  Node clocks must be synchronized (as with NTP), as expirations and
  versions are times.

  Contacts registered through a connection (with `Caracola.Outbound`, or
  behind an edge proxy with Path) are reached through the node or proxy
  that has it: their Path points to it, and the other nodes send the
  requests there.

  ## Configuration

  Under the `:registrar_cluster` key:

    * `:sync_interval` - milliseconds between syncs (default 60000).
  """

  use Malla.Plugin, plugin_deps: [Caracola.Registrar]

  require Logger

  alias Caracola.Registrar.Store

  # Time removed AORs are kept, in seconds
  @tombstone 300

  @schema NimbleOptions.new!(sync_interval: [type: :pos_integer, default: 60_000])

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Merges the registrations of another node of the service (any of them if
  `node` is `nil`). Returns the node, or `:no_nodes`.
  """
  @spec sync(module(), node() | nil) :: {:ok, node()} | {:error, term()}
  def sync(service, node \\ nil) do
    case node || Enum.find(Malla.Node.get_nodes(service), &(&1 != node())) do
      nil ->
        {:error, :no_nodes}

      peer ->
        entries = :erpc.call(peer, Store, :dump, [service], 10_000)
        Store.load(service, entries)
        {:ok, peer}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  # Applies a change sent by another node, if the service runs here
  def apply_change(service, change) do
    if Process.whereis(service), do: do_apply_change(service, change), else: false
  end

  defp do_apply_change(service, {:write, aor, contacts, expires, version}),
    do: Store.write(service, aor, contacts, expires, version)

  defp do_apply_change(service, :del_all), do: Store.op(:del_all, service)

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    with {:ok, opts} <-
           NimbleOptions.validate(Keyword.get(config, :registrar_cluster, []), @schema) do
      {:ok, Keyword.put(config, :registrar_cluster, opts)}
    end
  end

  @impl true
  def plugin_start(srv_id, config) do
    interval = config[:registrar_cluster][:sync_interval]
    {:ok, children: [{__MODULE__.Sync, {srv_id, interval}}]}
  end

  defcb sip_registrar_store({:get, _aor} = op, service), do: Store.op(op, service)

  def sip_registrar_store({:put, aor, contacts, ttl}, service),
    do: write(service, aor, contacts, System.os_time(:second) + ttl)

  def sip_registrar_store({:del, aor}, service) do
    case Store.op({:get, aor}, service) do
      [] -> :not_found
      _ -> write(service, aor, [], System.os_time(:second) + @tombstone)
    end
  end

  def sip_registrar_store(:del_all, service) do
    Store.op(:del_all, service)
    broadcast(service, :del_all)
  end

  def sip_registrar_store(_op, _service), do: :cont

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp write(service, aor, contacts, expires) do
    version = Store.version()
    Store.write(service, aor, contacts, expires, version)
    broadcast(service, {:write, aor, contacts, expires, version})
  end

  # To all the connected nodes, not only the ones known to run the service
  # (as Malla discovers them after a while)
  defp broadcast(service, change) do
    for node <- Node.list() do
      :erpc.cast(node, __MODULE__, :apply_change, [service, change])
    end

    :ok
  end

  defmodule Sync do
    @moduledoc false
    # Syncs the registrations of the service from another node when it
    # starts (retrying until there is one, as nodes are discovered after a
    # while) and periodically.

    use GenServer

    require Logger

    alias Caracola.Registrar.Cluster

    @retry 1_000

    def child_spec({service, _interval} = args),
      do: %{id: {__MODULE__, service}, start: {GenServer, :start_link, [__MODULE__, args]}}

    @impl true
    def init({service, interval}) do
      send(self(), :sync)
      {:ok, %{service: service, interval: interval, synced: false}}
    end

    @impl true
    def handle_info(:sync, state) do
      case Cluster.sync(state.service) do
        {:ok, node} ->
          if not state.synced,
            do: Logger.info("registrations synced from #{node}", service: state.service)

          Process.send_after(self(), :sync, state.interval)
          {:noreply, %{state | synced: true}}

        {:error, :no_nodes} ->
          # Not discovered yet, or alone
          Process.send_after(self(), :sync, if(state.synced, do: state.interval, else: @retry))
          {:noreply, state}

        {:error, reason} ->
          Logger.warning("could not sync registrations: #{inspect(reason)}",
            service: state.service
          )

          Process.send_after(self(), :sync, state.interval)
          {:noreply, state}
      end
    end
  end
end
