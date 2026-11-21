defmodule Caracola.RateLimit.Store do
  @moduledoc false
  # Counters and bans of Caracola.RateLimit, in an ETS table with entries
  # {key, count, expires} (monotonic milliseconds). Counters are kept per
  # fixed window: their key has the number of the window, and they expire
  # when it ends. Expired entries are removed periodically.

  use GenServer

  @table :caracola_rate_limit
  @sweep 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Counts a hit in the current window of `interval` ms, returning the
  # number of hits in it
  def hit(service, class, id, interval) do
    now = now()
    window = Integer.floor_div(now, interval)
    key = {service, class, id, window}
    :ets.update_counter(@table, key, {2, 1}, {key, 0, (window + 1) * interval})
  end

  def ban(service, ip, time) do
    :ets.insert(@table, {{service, :ban, ip}, 0, now() + time})
    :ok
  end

  def unban(service, ip) do
    :ets.delete(@table, {service, :ban, ip})
    :ok
  end

  def banned?(service, ip) do
    case :ets.lookup(@table, {service, :ban, ip}) do
      [{_, _, expires}] -> expires > now()
      [] -> false
    end
  end

  # Banned addresses and the milliseconds left
  def bans(service) do
    now = now()

    for {{_, :ban, ip}, _, expires} <- :ets.match_object(@table, {{service, :ban, :_}, :_, :_}),
        expires > now,
        do: {ip, expires - now}
  end

  def clear(service) do
    :ets.match_delete(@table, {{service, :_, :_}, :_, :_})
    :ets.match_delete(@table, {{service, :_, :_, :_}, :_, :_})
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
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
