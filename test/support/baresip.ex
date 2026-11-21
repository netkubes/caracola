defmodule Caracola.Test.Baresip do
  @moduledoc false
  # Runs baresip (https://github.com/baresip/baresip) for the
  # interoperability tests (test/interop/baresip_test.exs, tagged :baresip),
  # in a temporary directory, and drives it through its ctrl_tcp module
  # (JSON in netstrings). Its events are sent to the owner as
  # `{:baresip, name, event}`.
  #
  # baresip ignores loopback addresses, so it listens on the first
  # non-loopback IPv4 address of the host (`ip/0`), and the services it
  # talks to must listen there too.

  use GenServer

  alias Caracola.Test.Sipp

  defstruct [:name, :owner, :dir, :ip, :sip_port, :ctrl_port, :socket, buffer: "", calls: %{}]

  def available?, do: System.find_executable("baresip") != nil

  @doc "The first non-loopback IPv4 address of the host."
  def ip do
    {:ok, ifs} = :inet.getifaddrs()

    ifs
    |> Enum.find_value(fn {_name, opts} ->
      flags = opts[:flags] || []

      if :up in flags and :running in flags and :loopback not in flags,
        do: Enum.find(Keyword.get_values(opts, :addr), &(tuple_size(&1) == 4))
    end)
    |> case do
      nil -> raise "baresip tests need a non-loopback IPv4 address"
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  end

  @doc """
  Starts baresip with `accounts` (a list of account lines). Options:
  `name` (to tell the events of several instances apart), `owner`,
  `config` (extra config lines) and `contacts` (lines of the contacts file).
  """
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(opts, :owner, self()))

  # Evaluated in the test process, the owner by default
  def child_spec(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Address and port of its SIP listener."
  def info(pid), do: GenServer.call(pid, :info)

  @doc "Output of baresip, for failed tests."
  def output(pid), do: GenServer.call(pid, :output)

  @doc "Runs a command (as in the baresip menu), returning `{:ok | :error, text}`."
  def command(pid, command, params \\ ""), do: GenServer.call(pid, {:command, command, params})

  ## ===================================================================
  ## GenServer
  ## ===================================================================

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Path.join(System.tmp_dir!(), "caracola_bs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    state = %__MODULE__{
      name: Keyword.get(opts, :name, :baresip),
      owner: Keyword.fetch!(opts, :owner),
      dir: dir,
      ip: ip(),
      sip_port: Sipp.free_port(),
      ctrl_port: Sipp.free_port()
    }

    File.write!(Path.join(dir, "config"), config(state, Keyword.get(opts, :config, [])))
    File.write!(Path.join(dir, "accounts"), Enum.join(Keyword.fetch!(opts, :accounts), "\n"))
    File.write!(Path.join(dir, "contacts"), Enum.join(Keyword.get(opts, :contacts, []), "\n"))
    args = ["-f", dir, "-c", "-s"]
    out = File.stream!(Path.join(dir, "output"))
    Task.start(fn -> System.cmd("baresip", args, stderr_to_stdout: true, cd: dir, into: out) end)

    case connect(state.ctrl_port, 100) do
      {:ok, socket} ->
        {:ok, %{state | socket: socket}}

      {:error, reason} ->
        {:stop, {:baresip_not_started, reason}}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {state.ip, state.sip_port}, state}

  def handle_call(:output, _from, state),
    do: {:reply, File.read!(Path.join(state.dir, "output")), state}

  def handle_call({:command, command, params}, from, state) do
    token = Integer.to_string(System.unique_integer([:positive]))
    json = JSON.encode!(%{command: command, params: params, token: token})
    :ok = :gen_tcp.send(state.socket, "#{byte_size(json)}:#{json},")
    {:noreply, %{state | calls: Map.put(state.calls, token, from)}}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    {:noreply, parse(%{state | buffer: state.buffer <> data})}
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      json = JSON.encode!(%{command: "quit", params: "", token: "quit"})
      :gen_tcp.send(state.socket, "#{byte_size(json)}:#{json},")
      Process.sleep(200)
    end

    File.rm_rf(state.dir)
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp config(state, extra) do
    modules = "#{brew_prefix()}/lib/baresip/modules"

    """
    sip_listen\t#{state.ip}:#{state.sip_port}
    sip_transports\tudp,tcp
    call_accept\tno
    audio_player\taufile,#{state.dir}/play.wav
    audio_source\tausine,440
    audio_alert\taufile,#{state.dir}/alert.wav
    module_path\t#{modules}
    module\tg711.so
    module\tauconv.so
    module\tauresamp.so
    module\taufile.so
    module\tausine.so
    module\tuuid.so
    module_app\taccount.so
    module_app\tmenu.so
    module_app\tctrl_tcp.so
    ctrl_tcp_listen\t127.0.0.1:#{state.ctrl_port}
    #{Enum.join(extra, "\n")}
    """
  end

  defp brew_prefix do
    case System.cmd("brew", ["--prefix", "baresip"]) do
      {prefix, 0} -> String.trim(prefix)
      _ -> "/usr"
    end
  rescue
    _ -> "/usr"
  end

  defp connect(_port, 0), do: {:error, :timeout}

  defp connect(port, retries) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true], 1000) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, _} ->
        Process.sleep(50)
        connect(port, retries - 1)
    end
  catch
    :exit, _ ->
      Process.sleep(50)
      connect(port, retries - 1)
  end

  # Netstrings: "<length>:<json>,"
  defp parse(%{buffer: buffer} = state) do
    with [len, rest] <- :binary.split(buffer, ":"),
         {len, ""} <- Integer.parse(len),
         <<json::binary-size(^len), ?,, rest::binary>> <- rest do
      state = handle_json(JSON.decode!(json), %{state | buffer: rest})
      parse(state)
    else
      _ -> state
    end
  end

  defp handle_json(%{"response" => true, "token" => token} = resp, state) do
    case Map.pop(state.calls, token) do
      {nil, _} ->
        state

      {from, calls} ->
        result = if resp["ok"], do: :ok, else: :error
        GenServer.reply(from, {result, resp["data"]})
        %{state | calls: calls}
    end
  end

  defp handle_json(%{"event" => true} = event, state) do
    send(state.owner, {:baresip, state.name, event})
    state
  end

  defp handle_json(_json, state), do: state
end
