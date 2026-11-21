defmodule Caracola.DNS.Cache do
  @moduledoc false
  # ETS cache for DNS lookups. The table is owned by this process, which also
  # removes expired entries periodically. Reads and writes go directly to
  # the table, and are skipped if it doesn't exist.

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Gets a cached value, or `:error` if missing or expired."
  @spec get(term()) :: {:ok, term()} | :error
  def get(key) do
    now = now()

    case lookup(key) do
      [{^key, value, expires}] when expires > now -> {:ok, value}
      _ -> :error
    end
  end

  @doc "Stores a value for the configured TTL (`:dns_cache_ttl`, in ms)."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    ttl = Application.get_env(:caracola, :dns_cache_ttl, :timer.minutes(5))
    if ttl > 0, do: insert({key, value, now() + ttl})
    :ok
  end

  @doc "Removes all entries."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end

  defp lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp insert(entry) do
    :ets.insert(@table, entry)
  rescue
    ArgumentError -> true
  end

  defp now, do: System.monotonic_time(:millisecond)
end
