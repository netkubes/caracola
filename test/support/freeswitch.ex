defmodule Caracola.Test.FreeSwitch do
  @moduledoc false
  # Runs FreeSWITCH (https://signalwire.com/freeswitch) for the
  # interoperability tests (test/interop/freeswitch_test.exs, tagged
  # :freeswitch), with the configuration in test/interop/freeswitch, in a
  # temporary directory and on free ports. It is driven through its event
  # socket.

  alias Caracola.Test.Sipp

  @conf Path.expand("../interop/freeswitch/freeswitch.xml", __DIR__)
  @esl_password "ClueCon"

  defstruct [:dir, :sip_port, :ws_port, :esl_port, password: "secret", domain: "127.0.0.1"]

  def available?, do: System.find_executable("freeswitch") != nil

  @doc "Starts FreeSWITCH, waiting until its SIP profile is running."
  def start do
    dir = Path.join(System.tmp_dir!(), "caracola_fs_#{System.unique_integer([:positive])}")
    for sub <- ~w(conf log run db temp certs), do: File.mkdir_p!(Path.join(dir, sub))
    rtp = 20_000 + :rand.uniform(400) * 100

    fs = %__MODULE__{
      dir: dir,
      sip_port: Sipp.free_port(),
      ws_port: Sipp.free_port(),
      esl_port: Sipp.free_port()
    }

    File.cp!(@conf, Path.join(dir, "conf/freeswitch.xml"))

    vars =
      [
        domain: fs.domain,
        password: fs.password,
        sip_port: fs.sip_port,
        ws_port: fs.ws_port,
        esl_port: fs.esl_port,
        rtp_start: rtp,
        rtp_end: rtp + 99
      ]
      |> Enum.map_join("\n", fn {k, v} -> ~s(  <X-PRE-PROCESS cmd="set" data="#{k}=#{v}"/>) end)

    File.write!(Path.join(dir, "conf/vars.xml"), "<include>\n#{vars}\n</include>\n")

    args =
      ~w(-nonat -nocal -nf -nc -np -nosql) ++
        Enum.flat_map(~w(conf log run db temp certs), &["-#{&1}", Path.join(dir, &1)]) ++
        ["-mod", mod_dir()]

    Task.start(fn -> System.cmd("freeswitch", args, stderr_to_stdout: true, cd: dir) end)

    try do
      wait_ready(fs, 100)
    rescue
      error ->
        stop(fs)
        reraise error, __STACKTRACE__
    end
  end

  @doc "Stops FreeSWITCH, and removes its directory."
  def stop(%__MODULE__{dir: dir}) do
    System.cmd("freeswitch", ["-stop", "-run", Path.join(dir, "run")], stderr_to_stdout: true)
    File.rm_rf!(dir)
  end

  defp mod_dir do
    {prefix, 0} = System.cmd("brew", ["--prefix", "freeswitch"])
    Path.join(String.trim(prefix), "lib/freeswitch/mod")
  rescue
    _ -> "/usr/lib/freeswitch/mod"
  end

  defp wait_ready(_fs, 0), do: raise("FreeSWITCH did not start")

  defp wait_ready(fs, retries) do
    case api(fs, "sofia status profile internal") do
      {:ok, status} ->
        if status =~ "BIND-URL", do: fs, else: retry(fs, retries)

      {:error, _} ->
        retry(fs, retries)
    end
  end

  defp retry(fs, retries) do
    Process.sleep(100)
    wait_ready(fs, retries - 1)
  end

  @doc """
  Runs an API command through the event socket (`fs_cli -x`), returning
  its output.
  """
  def api(%__MODULE__{esl_port: port}, command, timeout \\ 10_000) do
    opts = [:binary, active: false, packet: :line]

    with {:ok, socket} <- connect(port, opts) do
      try do
        {:ok, _, _} = read(socket, timeout)
        :ok = :gen_tcp.send(socket, "auth #{@esl_password}\n\n")
        {:ok, %{"reply-text" => "+OK" <> _}, _} = read(socket, timeout)
        :ok = :gen_tcp.send(socket, "api #{command}\n\n")
        {:ok, _, body} = read(socket, timeout)
        {:ok, body}
      after
        :gen_tcp.close(socket)
      end
    end
  end

  # While FreeSWITCH starts, connect can fail with einval (an exit)
  defp connect(port, opts) do
    :gen_tcp.connect({127, 0, 0, 1}, port, opts, 1000)
  catch
    :exit, reason -> {:error, reason}
  end

  # An event socket message: headers, and a body of Content-Length bytes
  defp read(socket, timeout, headers \\ %{}) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, "\n"} ->
        case headers do
          %{"content-length" => len} -> {:ok, headers, body(socket, String.to_integer(len))}
          _ -> {:ok, headers, ""}
        end

      {:ok, line} ->
        [name, value] = String.split(String.trim_trailing(line), ": ", parts: 2)
        read(socket, timeout, Map.put(headers, String.downcase(name), value))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp body(socket, len) do
    :ok = :inet.setopts(socket, packet: :raw)
    {:ok, body} = :gen_tcp.recv(socket, len, 10_000)
    body
  end
end
