defmodule Caracola.Notifier.Store do
  @moduledoc false
  # Watchers of Caracola.Notifier: an ordered ETS table with the
  # subscriptions of each service, event and resource, the version of
  # their next NOTIFY, their status and the watcher (its URI and start
  # time), and another one with the resource of each
  # subscription. A third one has the items of the state of resources kept
  # by the notifier plugins.

  use GenServer

  @watchers :caracola_notifier
  @handles :caracola_notifier_handles
  @items :caracola_notifier_items

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def add(handle, service, event, aor, status, watcher) do
    :ets.insert(@watchers, {{service, event, aor, handle}, 0, status, watcher})
    :ets.insert(@handles, {handle, {service, event, aor}})
    :ok
  end

  def lookup(handle) do
    case :ets.lookup(@handles, handle) do
      [{_, key}] -> key
      [] -> nil
    end
  end

  def remove(handle) do
    case :ets.take(@handles, handle) do
      [{_, {service, event, aor}}] -> :ets.delete(@watchers, {service, event, aor, handle})
      [] -> :ok
    end

    :ok
  end

  def watchers(service, event, aor) do
    for {{_, _, _, handle}, _, _, _} <-
          :ets.match_object(@watchers, {{service, event, aor, :_}, :_, :_, :_}),
        do: handle
  end

  def info(service, event, aor) do
    for {{_, _, _, handle}, _, status, watcher} <-
          :ets.match_object(@watchers, {{service, event, aor, :_}, :_, :_, :_}),
        do: {handle, status, watcher}
  end

  def status(handle) do
    with {service, event, aor} <- lookup(handle),
         [{_, _, status, _}] <- :ets.lookup(@watchers, {service, event, aor, handle}) do
      status
    else
      _ -> nil
    end
  end

  def set_status(handle, status) do
    case lookup(handle) do
      {service, event, aor} ->
        :ets.update_element(@watchers, {service, event, aor, handle}, {3, status})

      nil ->
        false
    end
  end

  # The version for the next NOTIFY, nil if the subscription is gone
  def next_version(handle) do
    case lookup(handle) do
      {service, event, aor} ->
        :ets.update_counter(@watchers, {service, event, aor, handle}, {2, 1}) - 1

      nil ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  def put_item(service, event, aor, key, nil) do
    :ets.delete(@items, {service, event, aor, key})
    :ok
  end

  def put_item(service, event, aor, key, value) do
    :ets.insert(@items, {{service, event, aor, key}, value})
    :ok
  end

  def items(service, event, aor) do
    for {{_, _, _, key}, value} <- :ets.match_object(@items, {{service, event, aor, :_}, :_}),
        do: {key, value}
  end

  @impl true
  def init(nil) do
    :ets.new(@watchers, [:named_table, :public, :ordered_set])
    :ets.new(@handles, [:named_table, :public, :set])
    :ets.new(@items, [:named_table, :public, :ordered_set])
    {:ok, nil}
  end
end
