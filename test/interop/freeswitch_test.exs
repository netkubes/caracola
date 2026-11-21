defmodule Caracola.Interop.FreeSwitchTest do
  # Interoperability with FreeSWITCH. Run with `mix test --only freeswitch`.
  use ExUnit.Case, async: false

  @moduletag :freeswitch
  @moduletag timeout: 120_000

  alias Caracola.Interop.{B2B, FsUA1, FsUA2}
  alias Caracola.{SDP, UAC}
  alias Caracola.Test.FreeSwitch

  import Caracola.Test.Helpers, only: [start_service: 2, start_service: 1, port: 1, eventually: 1]

  setup_all do
    if not FreeSwitch.available?(), do: raise("freeswitch is not installed")
    fs = FreeSwitch.start()
    on_exit(fn -> FreeSwitch.stop(fs) end)
    %{fs: fs}
  end

  defp uri(fs, user), do: "sip:#{user}@#{fs.domain}:#{fs.sip_port}"

  defp aor(fs, user), do: "sip:#{user}@#{fs.domain}"

  defp offer do
    SDP.new("127.0.0.1", [
      {"audio", 4000, [{:rtpmap, 0, "PCMU/8000"}, {:rtpmap, 101, "telephone-event/8000"}]}
    ])
  end

  defp register(service, fs, user, opts \\ []) do
    UAC.register(
      service,
      "sip:#{fs.domain}:#{fs.sip_port}",
      opts ++ [:contact, from: aor(fs, user), to: aor(fs, user), password: fs.password]
    )
  end

  defp registered?(fs, user) do
    {:ok, regs} = FreeSwitch.api(fs, "sofia status profile internal reg")
    regs =~ "#{user}@#{fs.domain}"
  end

  # A call from a user, authenticating with FreeSWITCH
  defp invite(service, fs, from, to, opts \\ []) do
    UAC.invite(
      service,
      uri(fs, to),
      opts ++ [:auto_2xx_ack, from: aor(fs, from), password: fs.password, body: offer()]
    )
  end

  describe "registrar" do
    test "register, refresh and unregister", %{fs: fs} do
      start_service(FsUA1)
      assert {:ok, 200, []} = register(FsUA1, fs, 1000)
      eventually(fn -> registered?(fs, 1000) end)
      assert {:ok, 200, []} = register(FsUA1, fs, 1000, expires: 300)
      assert {:ok, 200, []} = register(FsUA1, fs, 1000, [:unregister])
      eventually(fn -> not registered?(fs, 1000) end)
    end

    test "wrong password", %{fs: fs} do
      start_service(FsUA1)
      assert {:ok, code, []} = register(FsUA1, fs, 1002, password: "wrong")
      assert code in [401, 403]
      Process.sleep(200)
      refute registered?(fs, 1002)
    end
  end

  describe "applications" do
    test "echo: hold, DTMF over INFO and BYE", %{fs: fs} do
      start_service(FsUA1)
      offer = offer()

      assert {:ok, 200, [dialog: dialog, body: body]} =
               invite(FsUA1, fs, 1000, 9196, body: offer, get_meta: [:body])

      assert {:ok, %SDP{medias: [answer | _]}} = SDP.parse(body)
      assert answer.port > 0

      # Hold
      assert {:ok, 200, [dialog: ^dialog, body: body]} =
               UAC.invite(dialog, [
                 :auto_2xx_ack,
                 body: SDP.update(offer, :sendonly),
                 get_meta: [:body]
               ])

      assert {:ok, %SDP{medias: [held | _]}} = SDP.parse(body)
      assert {"recvonly", []} in held.attributes

      assert {:ok, 200, []} =
               UAC.info(dialog,
                 body: "Signal=5\r\nDuration=160\r\n",
                 content_type: "application/dtmf-relay"
               )

      assert {:ok, 200, []} = UAC.bye(dialog)
    end

    test "FreeSWITCH hangs up", %{fs: fs} do
      start_service(FsUA1)
      assert {:ok, 200, [dialog: _]} = invite(FsUA1, fs, 1000, 9664)
      assert {:ok, "+OK" <> _} = FreeSwitch.api(fs, "hupall NORMAL_CLEARING")
      assert_receive {FsUA1, :bye}
    end

    test "unknown extension and unauthenticated call", %{fs: fs} do
      start_service(FsUA1)
      assert {:ok, code, []} = invite(FsUA1, fs, 1000, 5555)
      assert code in [404, 480, 484]
      assert {:ok, 403, []} = invite(FsUA1, fs, 1000, 9196, password: "wrong")
    end
  end

  describe "through the Caracola B2BUA" do
    # FsUA1 calls FreeSWITCH through B2B, that authenticates the B leg
    setup %{fs: fs} do
      start_service(FsUA1)
      start_service(B2B, target: uri(fs, 9196), bridge_opts: [password: fs.password])
      %{b2b: "sip:9196@127.0.0.1:#{port(B2B)}"}
    end

    defp b2b_invite(b2b, fs, opts \\ []),
      do: UAC.invite(FsUA1, b2b, opts ++ [:auto_2xx_ack, from: aor(fs, 1000), body: offer()])

    test "echo: hold, DTMF over INFO and BYE", %{fs: fs, b2b: b2b} do
      assert {:ok, 200, [dialog: dialog, body: body]} = b2b_invite(b2b, fs, get_meta: [:body])
      assert {:ok, %SDP{medias: [answer | _]}} = SDP.parse(body)
      assert answer.port > 0
      assert_receive {:b2bua, :answered, _}

      # The re-INVITE and the INFO go to FreeSWITCH, and its answers back
      assert {:ok, 200, [dialog: ^dialog, body: body]} =
               UAC.invite(dialog, [
                 :auto_2xx_ack,
                 body: SDP.update(offer(), :sendonly),
                 get_meta: [:body]
               ])

      assert {:ok, %SDP{medias: [held | _]}} = SDP.parse(body)
      assert {"recvonly", []} in held.attributes

      assert {:ok, 200, []} =
               UAC.info(dialog,
                 body: "Signal=5\r\nDuration=160\r\n",
                 content_type: "application/dtmf-relay"
               )

      assert {:ok, 200, []} = UAC.bye(dialog)
      assert_receive {:b2bua, {:stop, {:bye, :a}}, _}
    end

    test "FreeSWITCH hangs up", %{fs: fs, b2b: b2b} do
      assert {:ok, 200, [dialog: _]} = b2b_invite(b2b, fs)
      assert_receive {:b2bua, :answered, _}
      assert {:ok, "+OK" <> _} = FreeSwitch.api(fs, "hupall NORMAL_CLEARING")
      assert_receive {:b2bua, {:stop, {:bye, :b}}, _}, 5000
      assert_receive {FsUA1, :bye}
    end

    test "to a registered user, through both B2BUAs", %{fs: fs} do
      start_service(FsUA2, ring: true)
      assert {:ok, 200, []} = register(FsUA2, fs, 1001)
      stop_supervised!(B2B)
      start_service(B2B, target: uri(fs, 1001), bridge_opts: [password: fs.password])
      b2b = "sip:1001@127.0.0.1:#{port(B2B)}"

      # Ringing and cancelled by the caller
      parent = self()
      callback = fn {:resp, code, _} -> send(parent, {:resp, code}) end
      assert {:async, handle} = b2b_invite(b2b, fs, [:async, callback: callback])
      assert_receive {FsUA2, {:invite, "1000"}}, 5000
      assert_receive {:resp, 180}, 5000
      assert :ok = UAC.cancel(handle)
      assert_receive {:resp, 487}, 5000
      assert_receive {FsUA2, :cancel}, 5000
      assert_receive {:b2bua, {:stop, :cancelled}, _}
    end
  end

  describe "FreeSWITCH as B2BUA" do
    setup %{fs: fs} do
      start_service(FsUA1)
      assert {:ok, 200, []} = register(FsUA1, fs, 1000)
      :ok
    end

    test "call between registered users, hung up by both sides", %{fs: fs} do
      start_service(FsUA2)
      assert {:ok, 200, []} = register(FsUA2, fs, 1001)

      # Caller hangs up
      assert {:ok, 200, [dialog: dialog]} = invite(FsUA1, fs, 1000, 1001)
      assert_receive {FsUA2, {:invite, "1000"}}
      assert_receive {FsUA2, {:ack, _}}
      assert {:ok, 200, []} = UAC.bye(dialog)
      assert_receive {FsUA2, :bye}

      # Callee hangs up
      assert {:ok, 200, [dialog: _]} = invite(FsUA1, fs, 1000, 1001)
      assert_receive {FsUA2, {:ack, dialog2}}
      assert {:ok, 200, []} = UAC.bye(dialog2)
      assert_receive {FsUA1, :bye}
    end

    test "busy", %{fs: fs} do
      start_service(FsUA2, busy: true)
      assert {:ok, 200, []} = register(FsUA2, fs, 1001)
      assert {:ok, 486, []} = invite(FsUA1, fs, 1000, 1001)
    end

    test "cancel", %{fs: fs} do
      start_service(FsUA2, ring: true)
      assert {:ok, 200, []} = register(FsUA2, fs, 1001)
      parent = self()
      callback = fn {:resp, code, _} -> send(parent, {:resp, code}) end
      assert {:async, handle} = invite(FsUA1, fs, 1000, 1001, [:async, callback: callback])
      assert_receive {FsUA2, {:invite, "1000"}}
      assert_receive {:resp, 180}
      assert :ok = UAC.cancel(handle)
      assert_receive {:resp, 487}
      assert_receive {FsUA2, :cancel}
    end
  end

  describe "calls from FreeSWITCH" do
    test "originate and hang up", %{fs: fs} do
      start_service(FsUA1)
      target = "sofia/internal/test@127.0.0.1:#{port(FsUA1)}"
      assert {:ok, "+OK " <> uuid} = FreeSwitch.api(fs, "originate #{target} &park()")
      assert_receive {FsUA1, {:invite, _}}
      assert_receive {FsUA1, {:ack, _}}
      assert {:ok, "+OK" <> _} = FreeSwitch.api(fs, "uuid_kill #{String.trim(uuid)}")
      assert_receive {FsUA1, :bye}
    end
  end
end
