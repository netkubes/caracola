defmodule Caracola.Registrar.Store do
  @moduledoc false
  # Built-in registrar storage (the default sip_registrar_store/2): an ETS
  # table with the contacts of each service and AOR, their expiration and
  # their version (the time they were written, in microseconds). Expired
  # entries are ignored and removed periodically.
  #
  # Caracola.Registrar.Cluster replicates the writes among nodes: a write
  # is only applied if it is newer than the current one, and deleted AORs
  # are kept for a while without contacts (tombstones), so that older
  # writes arriving later do not bring them back.

  use GenServer

  @table :caracola_registrar
  @sweep 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc false
  def op({:get, aor}, service) do
    now = System.os_time(:second)

    case :ets.lookup(@table, {service, aor}) do
      [{_, contacts, expires, _version}] when expires > now -> contacts
      _ -> []
    end
  end

  def op({:put, aor, contacts, ttl}, service) do
    :ets.insert(@table, {{service, aor}, contacts, System.os_time(:second) + ttl, version()})
    :ok
  end

  def op({:del, aor}, service) do
    case op({:get, aor}, service) do
      [] ->
        :not_found

      _ ->
        :ets.delete(@table, {service, aor})
        :ok
    end
  end

  def op(:del_all, service) do
    :ets.match_delete(@table, {{service, :_}, :_, :_, :_})
    :ok
  end

  @doc false
  # A new version, for writes made in this node
  def version, do: System.os_time(:microsecond)

  @doc false
  # Writes the contacts of an AOR if the version is newer than the current
  # one. Returns true if written.
  def write(service, aor, contacts, expires, version) do
    key = {service, aor}

    case :ets.lookup(@table, key) do
      [{_, _, _, current}] when current >= version ->
        false

      _ ->
        :ets.insert(@table, {key, contacts, expires, version})
        true
    end
  end

  @doc false
  # The entries of a service that have not expired, as
  # {aor, contacts, expires, version}
  def dump(service) do
    now = System.os_time(:second)

    for {{_, aor}, contacts, expires, version} <-
          :ets.match_object(@table, {{service, :_}, :_, :_, :_}),
        expires > now,
        do: {aor, contacts, expires, version}
  end

  @doc false
  def load(service, entries) do
    for {aor, contacts, expires, version} <- entries,
        do: write(service, aor, contacts, expires, version)

    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, @sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.os_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end
end
