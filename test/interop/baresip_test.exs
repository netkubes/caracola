defmodule Caracola.Interop.BaresipTest do
  # Interoperability with baresip. Run with `mix test --only baresip`.
  use ExUnit.Case, async: false

  @moduletag :baresip
  @moduletag timeout: 120_000

  alias Caracola.Interop.{B2B, BsProxy, FsUA1}
  alias Caracola.{Registrar, UAC}
  alias Caracola.Test.Baresip

  import Caracola.Test.Helpers, only: [start_service: 2, eventually: 1]

  setup_all do
    if not Baresip.available?(), do: raise("baresip is not installed")
    %{ip: Baresip.ip()}
  end

  defmacrop assert_event(name, type, timeout \\ 5_000) do
    quote do
      assert_receive {:baresip, n, %{"type" => unquote(type)} = event}
                     when n == unquote(name),
                     unquote(timeout)

      event
    end
  end

  # Messages received by the proxy are sent to the test as
  # {:proxy, method_or_code, message}
  defp watch_proxy do
    id = {__MODULE__, self()}
    :telemetry.attach(id, [:caracola, :message, :received], &__MODULE__.proxy_message/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def proxy_message(_event, _measurements, %{service: BsProxy, message: msg}, test) do
    key =
      case msg.class do
        {:req, method} -> method
        {:resp, code, _} -> {code, elem(msg.cseq, 1)}
      end

    send(test, {:proxy, key, msg})
  end

  def proxy_message(_event, _measurements, _meta, _test), do: :ok

  # The proxy, listening on the address baresip can reach
  # Bindings and publications of previous tests are removed
  defp start_proxy(ip, config \\ []) do
    port = start_service(BsProxy, [sip: [listen: "sip:#{ip}:0"]] ++ config)
    Registrar.clear(BsProxy)
    Caracola.EventCompositor.clear(BsProxy)
    port
  end

  # A baresip phone registered as `user` through the proxy
  defp phone(name, user, ip, port, params \\ ";answermode=auto") do
    account =
      "<sip:#{user}@malla.test>;auth_pass=secret;regint=60" <>
        ";outbound=\"sip:#{ip}:#{port}\"" <> params

    pid = start_supervised!({Baresip, name: name, accounts: [account]})
    wait_registered(pid, 100)
    pid
  end

  # REGISTER_OK can come before the control connection, so the state is
  # polled
  defp wait_registered(_pid, 0), do: flunk("baresip did not register")

  defp wait_registered(pid, retries) do
    {:ok, info} = Baresip.command(pid, "reginfo")

    if info =~ "OK" do
      :ok
    else
      Process.sleep(50)
      wait_registered(pid, retries - 1)
    end
  end

  describe "Caracola as registrar" do
    test "register and unregister", %{ip: ip} do
      port = start_proxy(ip)
      bs = phone(:a, 1000, ip, port)
      assert [%Caracola.URI{}] = Registrar.find(BsProxy, :sip, "1000", "malla.test")
      # Deleting the user agent unregisters it
      assert {:ok, _} = Baresip.command(bs, "uadel", "sip:1000@malla.test")
      eventually(fn -> Registrar.find(BsProxy, :sip, "1000", "malla.test") == [] end)
    end
  end

  describe "calls through the Caracola proxy" do
    setup %{ip: ip} do
      port = start_proxy(ip)
      %{port: port}
    end

    test "established and hung up by both sides", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port)
      b = phone(:b, 1001, ip, port)

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_INCOMING")
      assert_event(:a, "CALL_ESTABLISHED")
      assert_event(:b, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(a, "hangup")
      assert_event(:a, "CALL_CLOSED")
      assert_event(:b, "CALL_CLOSED")

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_event(:a, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(b, "hangup")
      assert_event(:b, "CALL_CLOSED")
      assert_event(:a, "CALL_CLOSED")
    end

    test "unknown user", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port)
      assert {:ok, _} = Baresip.command(a, "dial", "sip:1009@malla.test")
      assert %{"param" => reason} = assert_event(:a, "CALL_CLOSED")
      assert reason =~ "480"
    end

    test "cancel", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port)
      phone(:b, 1001, ip, port, ";answermode=manual")
      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_INCOMING")
      assert_event(:a, "CALL_RINGING")
      assert {:ok, _} = Baresip.command(a, "hangup")
      assert_event(:a, "CALL_CLOSED")
      assert_event(:b, "CALL_CLOSED")
    end
  end

  describe "calls through the Caracola B2BUA" do
    setup %{ip: ip} do
      port = start_service(B2B, sip: [listen: "sip:#{ip}:0"])
      Registrar.clear(B2B)
      %{port: port}
    end

    test "established and hung up by both sides", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port)
      b = phone(:b, 1001, ip, port)

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert %{"peeruri" => "sip:1000@malla.test"} = assert_event(:b, "CALL_INCOMING")
      assert_event(:a, "CALL_ESTABLISHED")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_receive {:b2bua, :answered, bridge}
      assert bridge.a_call_id != bridge.b_call_id
      assert {:ok, _} = Baresip.command(a, "hangup")
      assert_event(:a, "CALL_CLOSED")
      assert_event(:b, "CALL_CLOSED")
      assert_receive {:b2bua, {:stop, {:bye, :a}}, _}

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_event(:a, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(b, "hangup")
      assert_event(:b, "CALL_CLOSED")
      assert_event(:a, "CALL_CLOSED")
      assert_receive {:b2bua, {:stop, {:bye, :b}}, _}
    end

    test "hold, resume and DTMF over INFO", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port, ";answermode=auto;dtmfmode=info")
      b = phone(:b, 1001, ip, port, ";answermode=auto;dtmfmode=info")
      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_event(:a, "CALL_ESTABLISHED")

      # re-INVITEs from both sides go to the other leg
      assert {:ok, _} = Baresip.command(a, "hold")
      assert %{"remoteaudiodir" => "recvonly"} = assert_event(:b, "CALL_HOLD")
      assert {:ok, _} = Baresip.command(a, "resume")
      assert %{"remoteaudiodir" => "sendrecv"} = assert_event(:b, "CALL_RESUME")
      assert {:ok, _} = Baresip.command(b, "hold")
      assert %{"remoteaudiodir" => "recvonly"} = assert_event(:a, "CALL_HOLD")

      assert {:ok, _} = Baresip.command(a, "sndcode", "5")
      assert %{"param" => "5"} = assert_event(:b, "CALL_DTMF_START")

      assert {:ok, _} = Baresip.command(a, "hangup")
      assert_event(:b, "CALL_CLOSED")
    end

    test "busy, unknown user and cancel", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port)
      b = phone(:b, 1001, ip, port, ";answermode=manual")

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1009@malla.test")
      assert %{"param" => reason} = assert_event(:a, "CALL_CLOSED")
      assert reason =~ "480"

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_INCOMING")
      assert_event(:a, "CALL_RINGING")
      assert {:ok, _} = Baresip.command(a, "hangup")
      assert_event(:a, "CALL_CLOSED")
      assert_event(:b, "CALL_CLOSED")
      assert_receive {:b2bua, {:stop, :cancelled}, _}

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_INCOMING")
      assert {:ok, _} = Baresip.command(b, "hangup")
      assert %{"param" => reason} = assert_event(:a, "CALL_CLOSED")
      assert reason =~ "486"
      assert_receive {:b2bua, {:stop, {:rejected, 486}}, _}
    end
  end

  describe "Caracola as user agent" do
    test "baresip calls a Caracola UAS", %{ip: ip} do
      port = start_service(FsUA1, sip: [listen: "sip:#{ip}:0"])
      bs = start_supervised!({Baresip, name: :a, accounts: ["<sip:1000@#{ip}>;regint=0"]})

      assert {:ok, _} = Baresip.command(bs, "dial", "sip:test@#{ip}:#{port}")
      assert_receive {FsUA1, {:invite, "1000"}}
      assert_event(:a, "CALL_ESTABLISHED")
      assert_receive {FsUA1, {:ack, dialog}}
      assert {:ok, 200, []} = UAC.bye(dialog)
      assert_event(:a, "CALL_CLOSED")

      assert {:ok, _} = Baresip.command(bs, "dial", "sip:test@#{ip}:#{port}")
      assert_event(:a, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(bs, "hangup")
      assert_receive {FsUA1, :bye}
    end

    test "Caracola calls baresip", %{ip: ip} do
      start_service(FsUA1, sip: [listen: "sip:#{ip}:0"])

      bs =
        start_supervised!(
          {Baresip, name: :a, accounts: ["<sip:1000@#{ip}>;regint=0;answermode=auto"]}
        )

      {bs_ip, bs_port} = Baresip.info(bs)
      sdp = Caracola.SDP.new(ip, [{"audio", 4000, [{:rtpmap, 0, "PCMU/8000"}]}])

      assert {:ok, 200, [dialog: dialog]} =
               UAC.invite(FsUA1, "sip:1000@#{bs_ip}:#{bs_port}", [:auto_2xx_ack, body: sdp])

      assert_event(:a, "CALL_ESTABLISHED")
      assert {:ok, 200, []} = UAC.bye(dialog)
      assert_event(:a, "CALL_CLOSED")

      assert {:ok, 200, [dialog: _]} =
               UAC.invite(FsUA1, "sip:1000@#{bs_ip}:#{bs_port}", [:auto_2xx_ack, body: sdp])

      assert_event(:a, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(bs, "hangup")
      assert_receive {FsUA1, :bye}
    end
  end

  describe "features through the Caracola proxy" do
    setup %{ip: ip} do
      port = start_proxy(ip)
      watch_proxy()
      %{port: port}
    end

    test "hold, resume and DTMF over INFO", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port, ";answermode=auto;dtmfmode=info")
      phone(:b, 1001, ip, port, ";answermode=auto;dtmfmode=info")
      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_event(:a, "CALL_ESTABLISHED")

      # Directions as seen by the held phone
      assert {:ok, _} = Baresip.command(a, "hold")
      assert %{"remoteaudiodir" => "recvonly"} = assert_event(:b, "CALL_HOLD")
      assert {:ok, _} = Baresip.command(a, "resume")
      assert %{"remoteaudiodir" => "sendrecv"} = assert_event(:b, "CALL_RESUME")

      assert {:ok, _} = Baresip.command(a, "sndcode", "5")
      assert_receive {:proxy, :info, _}
      assert %{"param" => "5"} = assert_event(:b, "CALL_DTMF_START")

      assert {:ok, _} = Baresip.command(a, "hangup")
      assert_event(:b, "CALL_CLOSED")
    end

    test "reliable provisional responses", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port, ";answermode=auto;100rel=required")
      b = phone(:b, 1001, ip, port, ";answermode=manual;100rel=yes")
      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_INCOMING")
      # The PRACK goes through the proxy, and the call is answered once
      # it is accepted
      assert_receive {:proxy, :prack, _}, 5_000
      assert_receive {:proxy, {200, :prack}, _}, 5_000
      assert {:ok, _} = Baresip.command(b, "accept")
      assert_event(:a, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(b, "hangup")
      assert_event(:a, "CALL_CLOSED")
    end

    test "blind transfer", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port)
      b = phone(:b, 1001, ip, port)
      phone(:c, 1002, ip, port)

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_event(:a, "CALL_ESTABLISHED")

      # B transfers A to C
      assert {:ok, _} = Baresip.command(b, "transfer", "sip:1002@malla.test")
      assert_receive {:proxy, :refer, _}, 5_000
      assert_event(:c, "CALL_ESTABLISHED")
      assert_event(:b, "CALL_CLOSED")
      assert {:ok, _} = Baresip.command(a, "hangupall", "all")
      assert_event(:c, "CALL_CLOSED")
    end

    test "attended transfer (Replaces)", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port)
      b = phone(:b, 1001, ip, port)
      phone(:c, 1002, ip, port)

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_event(:a, "CALL_ESTABLISHED")

      # B consults C, and then transfers A to it
      assert {:ok, _} = Baresip.command(b, "atransferstart", "sip:1002@malla.test")
      assert_event(:c, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(b, "atransferexec")
      assert_receive {:proxy, :refer, _}, 5_000
      assert_replaces()

      assert_event(:c, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(a, "hangupall", "all")
      assert_event(:c, "CALL_CLOSED")
    end
  end

  describe "Replaces with a Caracola phone" do
    setup %{ip: ip} do
      port = start_proxy(ip)
      watch_proxy()
      %{port: port}
    end

    test "attended transfer to a Caracola phone", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port)
      b = phone(:b, 1001, ip, port)

      # C is a Caracola user agent, registered as 1002
      start_service(FsUA1, sip: [listen: "sip:#{ip}:0"])

      assert {:ok, 200, []} =
               UAC.register(FsUA1, "sip:#{ip}:#{port}", [
                 :contact,
                 from: "sip:1002@malla.test",
                 to: "sip:1002@malla.test",
                 password: "secret"
               ])

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_event(:a, "CALL_ESTABLISHED")

      # B consults C, and transfers A to it: A calls C replacing B
      assert {:ok, _} = Baresip.command(b, "atransferstart", "sip:1002@malla.test")
      assert_receive {FsUA1, {:invite, "1001"}}, 5_000
      assert_receive {FsUA1, {:ack, _}}, 5_000
      assert {:ok, _} = Baresip.command(b, "atransferexec")
      assert_replaces()
      assert_receive {FsUA1, {:invite, "1000"}}, 5_000
      assert_receive {FsUA1, {:ack, dialog}}, 5_000

      # C hangs up B, and talks to A
      assert_receive {:proxy, :bye, %{from: %{user: "1002"}}}, 5_000
      assert {:ok, 200, []} = UAC.bye(dialog, password: "secret")
      assert_event(:a, "CALL_CLOSED")
    end
  end

  describe "SIP outbound" do
    setup %{ip: ip} do
      port = start_proxy(ip)
      watch_proxy()
      %{port: port}
    end

    test "registration and calls through the flow", %{ip: ip, port: port} do
      a = phone(:a, 1000, ip, port, ";answermode=auto;sipnat=outbound")
      phone(:b, 1001, ip, port, ";answermode=auto;sipnat=outbound")

      assert_receive {:proxy, :register, %{supported: supported} = reg}
      assert "outbound" in supported
      assert [%{ext_params: params}] = reg.contacts
      assert List.keymember?(params, "reg-id", 0)

      assert {:ok, _} = Baresip.command(a, "dial", "sip:1001@malla.test")
      assert_event(:b, "CALL_ESTABLISHED")
      assert_event(:a, "CALL_ESTABLISHED")
      assert {:ok, _} = Baresip.command(a, "hangup")
      assert_event(:b, "CALL_CLOSED")
    end
  end

  describe "presence and messages" do
    setup %{ip: ip} do
      port = start_proxy(ip)
      watch_proxy()
      %{port: port}
    end

    # Phones publishing their presence to the proxy, and subscribed to each
    # other (presence=p2p)
    defp presence_phone(name, user, buddy, ip, port) do
      account =
        "<sip:#{user}@malla.test>;auth_pass=secret;regint=60;pubint=60" <>
          ";outbound=\"sip:#{ip}:#{port}\""

      pid =
        start_supervised!(
          {Baresip,
           name: name,
           accounts: [account],
           contacts: ["<sip:#{buddy}@malla.test>;presence=p2p"],
           config: ["module_app\tcontact.so", "module_app\tpresence.so"]}
        )

      wait_registered(pid, 100)
      pid
    end

    defp contact_status(pid) do
      {:ok, contacts} = Baresip.command(pid, "contacts")

      cond do
        contacts =~ "Online" -> :online
        contacts =~ "Offline" -> :offline
        true -> :unknown
      end
    end

    test "publish, subscribe, notify and message", %{ip: ip, port: port} do
      a = presence_phone(:a, 1000, 1001, ip, port)
      b = presence_phone(:b, 1001, 1000, ip, port)

      # Publications are stored by the proxy
      assert_receive {:proxy, :publish, _}, 5_000
      assert_receive {:proxy, :subscribe, _}, 5_000
      assert_receive {:proxy, :notify, _}, 5_000
      eventually(fn -> contact_status(a) == :online end)

      assert {:ok, _} = Baresip.command(b, "presence", "offline")
      eventually(fn -> contact_status(a) == :offline end)

      assert {:ok, _} = Baresip.command(a, "message", "hello")
      assert_receive {:proxy, :message, %{body: "hello"}}, 5_000
      assert_receive {:proxy, {200, :message}, _}, 5_000
    end
  end

  describe "presence server" do
    setup %{ip: ip} do
      port = start_proxy(ip, presence_server: true)
      watch_proxy()
      %{port: port}
    end

    test "publications notified by Caracola.Presence", %{ip: ip, port: port} do
      a = presence_phone(:a, 1000, 1001, ip, port)
      b = presence_phone(:b, 1001, 1000, ip, port)

      # The proxy answers the SUBSCRIBEs and sends the NOTIFYs itself
      assert_receive {:proxy, :publish, _}, 5_000
      assert_receive {:proxy, :subscribe, %{event: {"presence", _}}}, 5_000
      assert_receive {:proxy, {200, :notify}, _}, 5_000
      refute_received {:proxy, :notify, _}
      eventually(fn -> contact_status(a) == :online end)
      eventually(fn -> contact_status(b) == :online end)

      assert [_] = Caracola.Notifier.watchers(BsProxy, "presence", {:sip, "1001", "malla.test"})
      assert {:ok, _} = Baresip.command(b, "presence", "offline")
      eventually(fn -> contact_status(a) == :offline end)
      assert {:ok, _} = Baresip.command(b, "presence", "online")
      eventually(fn -> contact_status(a) == :online end)
    end
  end

  # The INVITE with Replaces from the transferred phone
  defp assert_replaces do
    assert_receive {:proxy, :invite, %{headers: headers}}, 5_000
    if not List.keymember?(headers, "replaces", 0), do: assert_replaces()
  end
end
