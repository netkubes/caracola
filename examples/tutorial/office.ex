defmodule Caracola.Tutorial.Office do
  @moduledoc """
  Code of the [small PBX tutorial](15-small-pbx.md). `launch/0` runs all
  its steps.
  """

  alias Caracola.{DialogInfo, History, SDP, UAC}
  alias Caracola.Tutorial.Office.{Alice, Bob, PBX, Voicemail}

  @pbx "sip:127.0.0.1:5080"
  @route "<sip:127.0.0.1:5080;lr>"

  @doc """
  Starts the PBX and the three phones. The messages the phones want to tell
  (NOTIFYs, calls received) are sent to the calling process.
  """
  @spec start() :: :ok
  def start do
    for service <- [PBX, Alice, Bob, Voicemail] do
      {:ok, _} = service.start_link(test_pid: self())
      wait_ready(service)
    end

    :ok
  end

  defp wait_ready(service, retries \\ 100) do
    cond do
      Malla.Service.is_ready?(service) and Caracola.listeners(service) != [] -> :ok
      retries == 0 -> raise "#{inspect(service)} not ready"
      true -> wait_again(service, retries)
    end
  end

  defp wait_again(service, retries) do
    Process.sleep(20)
    wait_ready(service, retries - 1)
  end

  @doc "Stops the services."
  @spec stop() :: :ok
  def stop do
    for service <- [Voicemail, Bob, Alice, PBX], Process.whereis(service), do: service.stop()
    :ok
  end

  @doc "Runs all the steps of the tutorial, checking the results."
  @spec launch() :: :ok
  def launch do
    :ok = start()

    # The phones register
    for phone <- [Alice, Bob, Voicemail] do
      {:ok, 200, []} = UAC.register(phone, @pbx, [:contact, password: "1234"])
    end

    # Alice watches the line of Bob (a busy lamp)
    {:ok, 200, [subscription: _]} =
      UAC.subscribe(Alice, "sip:bob@example.com", event: "dialog", route: @route)

    %{dialogs: []} = next_notify()

    # Alice calls Bob. The PBX is a B2BUA: Bob sees a call from the PBX
    {:ok, 200, [dialog: dialog]} =
      UAC.invite(Alice, "sip:bob@example.com", [:auto_2xx_ack, route: @route, body: offer()])

    receive do
      {:invite, Bob, _req} -> :ok
    after
      1000 -> raise "Bob did not get the call"
    end

    # The lamp of Bob lights up
    wait_dialog_state(:confirmed)
    {:ok, 200, []} = UAC.bye(dialog)
    wait_dialog_state(:terminated)

    # Carol is out: the PBX forwards her calls to the voicemail
    {:ok, 200, [dialog: dialog]} =
      UAC.invite(Alice, "sip:carol@example.com", [:auto_2xx_ack, route: @route, body: offer()])

    receive do
      {:invite, Voicemail, req} ->
        [%{index: "1"}, %{index: "1.1", cause: 302}] = History.entries(req)
        [%{reason: "unconditional"}] = History.diversions(req)
    after
      1000 -> raise "the voicemail did not get the call"
    end

    {:ok, 200, []} = UAC.bye(dialog)
    stop()
  end

  defp offer, do: SDP.new("127.0.0.1", [{"audio", 1080, [{:rtpmap, 0, "PCMU/8000"}]}])

  defp next_notify do
    receive do
      {:notify, body} ->
        {:ok, doc} = DialogInfo.decode(body)
        doc
    after
      2000 -> raise "no NOTIFY"
    end
  end

  # Reads NOTIFYs until the dialog of Bob is in a state
  defp wait_dialog_state(state) do
    case next_notify() do
      %{dialogs: [%{state: ^state}]} -> :ok
      _ -> wait_dialog_state(state)
    end
  end
end

defmodule Caracola.Tutorial.Office.PBX do
  @moduledoc """
  The PBX of the [small PBX tutorial](15-small-pbx.md): a registrar, a B2BUA
  and a dialog state server for the `example.com` domain. It listens on
  `127.0.0.1`, port 5080.
  """

  use Malla.Service,
    plugins: [Caracola.Registrar, Caracola.B2BUA, Caracola.DialogInfo],
    sip: [listen: "sip:127.0.0.1:5080"],
    # Carol is out
    forward: %{"carol" => "voicemail"}

  alias Caracola.{B2BUA, History, Registrar, Transport}

  defcb sip_get_user_pass(_user, "example.com", _req, _call), do: "1234"
  defcb sip_get_user_pass(_user, _realm, _req, _call), do: false

  # Registered phones need no password for their requests
  defcb sip_authorize(auth_list, _req, _call) do
    cond do
      :dialog in auth_list or :register in auth_list ->
        :ok

      true ->
        case List.keyfind(auth_list, {:digest, "example.com"}, 0) do
          {_, true} -> :ok
          {_, _} -> :forbidden
          nil -> {:proxy_authenticate, "example.com"}
        end
    end
  end

  defcb sip_route(_scheme, nil, "example.com", _req, _call), do: :process

  # Calls to a user that forwards them are proxied to the extension that
  # receives them, adding History-Info and Diversion headers. All the other
  # requests are processed here.
  defcb sip_route(scheme, user, "example.com", req, call) do
    forward = call.service.get_config()[:forward]

    with {:req, :invite} <- req.class,
         ext when is_binary(ext) <- forward[user],
         [_ | _] = contacts <- Registrar.find(call.service, scheme, ext, "example.com") do
      History.retarget(req, contacts, [:diversion, cause: 302])
    else
      _ -> :process
    end
  end

  defcb sip_route(_scheme, _user, _domain, req, call) do
    if Transport.local?(call.service, req.ruri, call.config),
      do: :process,
      else: :proxy
  end

  # A call to a registered user is bridged to its first contact
  defcb sip_invite(req, call) do
    case Registrar.find(call.service, req.ruri.scheme, req.ruri.user, "example.com") do
      [] -> {:reply, :temporarily_unavailable}
      [contact | _] -> B2BUA.bridge(req, contact)
    end
  end
end

defmodule Caracola.Tutorial.Office.Phone do
  @moduledoc """
  Callbacks of the phones of the [small PBX tutorial](15-small-pbx.md): they
  answer calls and tell the process that started the services about the
  calls and NOTIFYs they receive.
  """

  defmacro __using__(_opts) do
    quote do
      alias Caracola.SDP

      defcb sip_invite(req, call) do
        send(call.service.get_config()[:test_pid], {:invite, call.service, req})

        case SDP.from_message(req) do
          %SDP{} = sdp ->
            spawn(fn -> Caracola.reply(req, {:answer, sdp}) end)
            :noreply

          nil ->
            {:reply, {:not_acceptable, "Invalid SDP"}}
        end
      end

      defcb sip_notify(req, call) do
        send(call.service.get_config()[:test_pid], {:notify, req.body})
        {:reply, :ok}
      end
    end
  end
end

for {name, user} <- [Alice: "alice", Bob: "bob", Voicemail: "voicemail"] do
  defmodule Module.concat(Caracola.Tutorial.Office, name) do
    @moduledoc """
    A phone of the [small PBX tutorial](15-small-pbx.md), for the
    `#{user}@example.com` extension. It listens on `127.0.0.1`, random
    ports.
    """

    use Malla.Service,
      plugins: [Caracola],
      sip: [listen: "sip:127.0.0.1:0", from: "sip:#{user}@example.com"]

    use Caracola.Tutorial.Office.Phone
  end
end
