defmodule Caracola.EventCompositor.Store do
  @moduledoc false
  # Built-in storage of the event compositor (the default
  # sip_event_compositor_store/2): an ETS table with the publications of
  # each service, AOR and tag (ordered, to list the ones of an AOR). Expired entries are ignored and removed
  # periodically.

  use GenServer

  @table :caracola_event_compositor
  @sweep 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc false
  def op({:get, aor, tag}, service) do
    now = System.os_time(:second)

    case :ets.lookup(@table, {service, aor, tag}) do
      [{_, pub, expires}] when expires > now -> pub
      _ -> :not_found
    end
  end

  def op({:list, aor}, service) do
    now = System.os_time(:second)

    for {{_, _, tag}, pub, expires} <- :ets.match_object(@table, {{service, aor, :_}, :_, :_}),
        expires > now,
        do: {tag, pub}
  end

  def op({:put, aor, tag, pub, ttl}, service) do
    :ets.insert(@table, {{service, aor, tag}, pub, System.os_time(:second) + ttl})
    :ok
  end

  def op({:del, aor, tag}, service) do
    :ets.delete(@table, {service, aor, tag})
    :ok
  end

  def op(:del_all, service) do
    :ets.match_delete(@table, {{service, :_, :_}, :_, :_})
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :ordered_set])
    Process.send_after(self(), :sweep, @sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.os_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end
end
