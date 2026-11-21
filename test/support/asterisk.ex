defmodule Caracola.Test.Asterisk do
  @moduledoc false
  # Runs Asterisk (https://www.asterisk.org) in a container, for the
  # interoperability tests (test/interop/asterisk_test.exs, tagged
  # :asterisk), with the configuration in test/interop/asterisk, and drives
  # it through its manager interface (AMI).
  #
  # The container is run with the docker CLI (with the `orbstack` context if
  # it exists, see ASTERISK_DOCKER_CONTEXT). Its SIP and AMI ports are
  # published on 127.0.0.1, and Asterisk announces that address and port in
  # its messages. It reaches the Caracola services at the first non-loopback
  # IPv4 address of the host (`Caracola.Test.Baresip.ip/0`).

  alias Caracola.Test.{Baresip, Sipp}

  @image "andrius/asterisk:22"
  @conf Path.expand("../interop/asterisk", __DIR__)
  @files ~w(extensions.conf manager.conf voicemail.conf)

  defstruct [:name, :dir, :sip_port, :ami_port, password: "secret", host: "127.0.0.1"]

  def available? do
    match?({_, 0}, docker(["version", "--format", "{{.Server.Version}}"]))
  rescue
    _ -> false
  end

  @doc """
  Starts Asterisk, waiting until it is fully booted. With
  `trunk: "ip:port"`, it registers as `asterisk@malla.test` (password
  "secret") through that proxy, and the `malla-trunk` endpoint sends
  calls to it.
  """
  def start(opts \\ []) do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "caracola_ast_#{n}")
    File.mkdir_p!(dir)
    ast = %__MODULE__{name: "caracola_ast_#{n}", dir: dir, sip_port: Sipp.free_port()}
    ast = %{ast | ami_port: Sipp.free_port()}

    # Transports announcing the published address
    pjsip =
      @conf
      |> Path.join("pjsip.conf")
      |> File.read!()
      |> String.replace(
        "bind=0.0.0.0:5060\n",
        """
        bind=0.0.0.0:5060
        external_signaling_address=127.0.0.1
        external_signaling_port=#{ast.sip_port}
        external_media_address=127.0.0.1
        local_net=127.0.0.1/32
        """
      )

    pjsip =
      case opts[:trunk] do
        nil -> pjsip
        proxy -> pjsip <> trunk(proxy)
      end

    File.write!(Path.join(dir, "pjsip.conf"), pjsip)
    for file <- @files, do: File.cp!(Path.join(@conf, file), Path.join(dir, file))

    volumes =
      Enum.flat_map(["pjsip.conf" | @files], &["-v", "#{dir}/#{&1}:/etc/asterisk/#{&1}:ro"])

    {_, 0} =
      docker(
        ["run", "-d", "--rm", "--name", ast.name, "-e", "ASTERISK_TERMINAL_OPTS=-n"] ++
          ["-p", "127.0.0.1:#{ast.sip_port}:5060/udp", "-p", "127.0.0.1:#{ast.sip_port}:5060/tcp"] ++
          ["-p", "127.0.0.1:#{ast.ami_port}:5038/tcp"] ++ volumes ++ [@image]
      )

    try do
      wait_ready(ast, 100)
    rescue
      error ->
        stop(ast)
        reraise error, __STACKTRACE__
    end
  end

  defp trunk(proxy) do
    """

    [malla-auth]
    type=auth
    auth_type=userpass
    username=asterisk
    password=secret
    supported_algorithms_uac=SHA-256,MD5

    [malla-reg]
    type=registration
    server_uri=sip:malla.test
    client_uri=sip:asterisk@malla.test
    contact_user=asterisk
    outbound_proxy=sip:#{proxy}\\;lr
    outbound_auth=malla-auth
    retry_interval=1
    forbidden_retry_interval=1
    expiration=60
    transport=transport-udp

    [malla-trunk](user)
    outbound_proxy=sip:#{proxy}\\;lr
    outbound_auth=malla-auth
    from_domain=malla.test
    """
  end

  @doc "Stops and removes the container."
  def stop(%__MODULE__{name: name, dir: dir}) do
    docker(["rm", "-f", name])
    File.rm_rf!(dir)
  end

  @doc "Log of Asterisk (with the SIP trace), for failed tests."
  def logs(%__MODULE__{name: name}) do
    {logs, _} = docker(["logs", name])
    logs
  end

  @doc "Address of the host for Asterisk (where Caracola services listen)."
  def host_ip, do: Baresip.ip()

  @doc "Runs a CLI command, returning its output."
  def cli(ast, command) do
    with {:ok, resp} <- ami(ast, [{"Action", "Command"}, {"Command", command}]) do
      {:ok, resp |> Enum.filter(&(elem(&1, 0) == "Output")) |> Enum.map_join("\n", &elem(&1, 1))}
    end
  end

  @doc """
  Sends a manager action (a list of `{name, value}`), returning the fields
  of its response.
  """
  def ami(%__MODULE__{ami_port: port}, action) do
    opts = [:binary, active: false, packet: :line]

    with {:ok, socket} <- connect(port, opts) do
      try do
        {:ok, _banner} = :gen_tcp.recv(socket, 0, 5000)
        login = [{"Action", "Login"}, {"Username", "test"}, {"Secret", "test"}]
        {:ok, [{"Response", "Success"} | _]} = request(socket, login, "login")
        request(socket, action, "action")
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp request(socket, fields, id) do
    data = Enum.map_join(fields ++ [{"ActionID", id}], &"#{elem(&1, 0)}: #{elem(&1, 1)}\r\n")
    :ok = :gen_tcp.send(socket, data <> "\r\n")
    response(socket, id)
  end

  # Messages are blocks of "Name: value" lines; events are skipped
  defp response(socket, id) do
    with {:ok, fields} <- read_block(socket, []) do
      if {"ActionID", id} in fields and List.keymember?(fields, "Response", 0),
        do: {:ok, fields},
        else: response(socket, id)
    end
  end

  defp read_block(socket, acc) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, "\r\n"} when acc != [] ->
        {:ok, Enum.reverse(acc)}

      {:ok, "\r\n"} ->
        read_block(socket, acc)

      {:ok, line} ->
        case String.split(String.trim_trailing(line), ": ", parts: 2) do
          [name, value] -> read_block(socket, [{name, value} | acc])
          [value] -> read_block(socket, [{"Output", value} | acc])
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(port, opts) do
    :gen_tcp.connect({127, 0, 0, 1}, port, opts, 1000)
  catch
    :exit, reason -> {:error, reason}
  end

  defp wait_ready(_ast, 0), do: raise("Asterisk did not start")

  defp wait_ready(ast, retries) do
    case cli(ast, "pjsip show transports") do
      {:ok, out} ->
        if out =~ "transport-udp" do
          {:ok, _} = cli(ast, "pjsip set logger on")
          ast
        else
          retry(ast, retries)
        end

      _ ->
        retry(ast, retries)
    end
  rescue
    _ -> retry(ast, retries)
  end

  defp retry(ast, retries) do
    Process.sleep(200)
    wait_ready(ast, retries - 1)
  end

  defp docker(args) do
    context = System.get_env("ASTERISK_DOCKER_CONTEXT", "orbstack")
    System.cmd("docker", ["--context", context | args], stderr_to_stdout: true)
  end
end
