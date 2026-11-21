defmodule Caracola.StirShaken.Certs do
  @moduledoc false
  # Cache of the public keys of the certificates of Caracola.StirShaken,
  # by service and URL: an ETS table with {{service, url}, key, expires}
  # entries (monotonic milliseconds). Expired entries are removed
  # periodically.

  use GenServer

  @table :caracola_stir_shaken_certs
  @sweep 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def get(service, url) do
    case :ets.lookup(@table, {service, url}) do
      [{_, key, expires}] -> if expires > now(), do: {:ok, key}, else: :error
      [] -> :error
    end
  end

  def put(service, url, key, time) do
    :ets.insert(@table, {{service, url}, key, now() + time})
    :ok
  end

  def clear(service) do
    :ets.match_delete(@table, {{service, :_}, :_, :_})
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end
end
