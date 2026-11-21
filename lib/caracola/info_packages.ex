defmodule Caracola.InfoPackages do
  @moduledoc """
  INFO packages (RFC 6086): the INFO requests of a dialog carry the
  package they belong to (`Info-Package`), and each side says in the
  `Recv-Info` header of its INVITEs and their responses which packages it
  accepts.

  ```
  defmodule MyUA do
    use Malla.Service,
      plugins: [Caracola.InfoPackages],
      sip: [listen: "sip:all:5060"],
      info_packages: ["dtmf"]

    defcb sip_info_package("dtmf", req, _call) do
      MyApp.dtmf(req.body)
      {:reply, :ok}
    end
  end

  Caracola.InfoPackages.send(dialog, "dtmf", "Signal=5\\r\\nDuration=160\\r\\n",
    content_type: "application/dtmf-relay")
  ```

  The packages of `:info_packages` (the configuration of the plugin) are
  added to the `:info_packages` of the sip configuration, so the INVITEs
  of the service and the 1xx and 2xx responses to them carry a
  `Recv-Info` with them.

  INFO requests with an `Info-Package` among them go to
  `sip_info_package(package, req, call)`, which returns a reply as
  `sip_info/2` (by default, it calls `sip_info/2`). INFOs for other
  packages are answered with 469 (Bad Info Package) and our `Recv-Info`.
  INFOs without `Info-Package` (legacy INFO, as most DTMF relays) go to
  `sip_info/2` as usual.

  `send/4` sends an INFO of a package, if the remote side accepts it (it
  was in the `Recv-Info` of its last INVITE or response to ours), and
  `remote_packages/1` returns the packages the remote side accepts.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.{Dialog, Message, Tokens, UAC, Util}

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc """
  Sends an INFO of a package in a dialog, with a body and the
  `Caracola.UAC` options (as `:content_type`). Returns
  `{:error, :bad_info_package}` if the remote side does not accept it.
  """
  @spec send(Dialog.handle(), String.t(), binary(), list()) :: UAC.result()
  def send(dialog, package, body, opts \\ []) do
    package = Util.ascii_downcase(package)

    if package in remote_packages(dialog) do
      headers = [
        {:replace, "info-package", package},
        {:replace, "content-disposition", "Info-Package"}
      ]

      UAC.info(dialog, headers ++ [body: body] ++ opts)
    else
      {:error, :bad_info_package}
    end
  end

  @doc """
  The packages the remote side of a dialog accepts: the `Recv-Info` of its
  last INVITE, or of its response to our last INVITE.
  """
  @spec remote_packages(Dialog.handle()) :: [String.t()]
  def remote_packages(dialog) do
    case Dialog.get(dialog) do
      {:ok, %Dialog{invite: %{class: :uac, response: %Message{} = resp}}} -> packages(resp)
      {:ok, %Dialog{invite: %{class: :uas, request: %Message{} = req}}} -> packages(req)
      _ -> []
    end
  end

  @doc """
  The packages of the `Recv-Info` (or `Info-Package`) header of a message.

      iex> {:ok, req, ""} = Caracola.Parser.parse("INFO sip:a@h SIP/2.0\\r\\nVia: SIP/2.0/UDP h;branch=z9hG4bKa\\r\\nFrom: <sip:a@h>;tag=1\\r\\nTo: <sip:b@h>;tag=2\\r\\nCall-ID: c\\r\\nCSeq: 1 INFO\\r\\nRecv-Info: dtmf, Foo;x=1\\r\\n\\r\\n")
      iex> Caracola.InfoPackages.packages(req)
      ["dtmf", "foo"]
  """
  @spec packages(Message.t(), String.t()) :: [String.t()]
  def packages(%Message{} = msg, header \\ "recv-info") do
    for value <- Message.header(msg, header),
        {:ok, tokens} <- [Tokens.parse(value)],
        {name, _} <- tokens,
        do: Util.ascii_downcase(name)
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config) do
    case Keyword.get(config, :info_packages, []) do
      packages when is_list(packages) ->
        packages = Enum.map(packages, &Util.ascii_downcase/1)
        {:ok, Caracola.Config.add_values(config, :info_packages, packages)}

      other ->
        {:error, {:invalid_config, {:info_packages, other}}}
    end
  end

  @doc false
  defcb sip_info_package(_package, req, call), do: call.service.sip_info(req, call)

  defcb caracola_callback(:sip_info, [req, call]) do
    case packages(req, "info-package") do
      [] ->
        :cont

      [package | _] ->
        accepted = call.config[:info_packages] || []

        if package in accepted do
          {:done, call.service.sip_info_package(package, req, call)}
        else
          recv_info = {:replace, "recv-info", Enum.join(accepted, ", ")}
          {:done, {:reply, {469, [recv_info, reason_phrase: "Bad Info Package"]}}}
        end
    end
  end

  def caracola_callback(_fun, _args), do: :cont
end
