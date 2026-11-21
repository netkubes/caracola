defmodule Caracola.Interop.AsteriskTest do
  # Interoperability with Asterisk, run in a container. Run with
  # `mix test --only asterisk`.
  use ExUnit.Case, async: false

  @moduletag :asterisk
  @moduletag timeout: 120_000

  alias Caracola.{DialogInfo, MessageWaiting, Presence, Registrar, SDP, UAC}
  alias Caracola.Interop.{B2B, BsProxy, FsUA1, FsUA2}
  alias Caracola.Test.{Asterisk, Sipp}

  import Caracola.Test.Helpers, only: [start_service: 2, eventually: 1, port: 1]

  setup_all do
    if not Asterisk.available?(), do: raise("docker is not available")
    ip = Asterisk.host_ip()
    # Asterisk registers through a Caracola proxy on this port
    proxy_port = Sipp.free_port()
    ast = Asterisk.start(trunk: "#{ip}:#{proxy_port}")
    on_exit(fn -> Asterisk.stop(ast) end)
    %{ast: ast, ip: ip, proxy_port: proxy_port}
  end

  # User agents listening where Asterisk can reach them
  defp start_ua(service, ip, config \\ []),
    do: start_service(service, [sip: [listen: "sip:#{ip}:0"]] ++ config)

  defp uri(ast, user), do: "sip:#{user}@#{ast.host}:#{ast.sip_port}"

  defp aor(ast, user), do: "sip:#{user}@#{ast.host}"

  defp offer(ip) do
    SDP.new(ip, [{"audio", 4000, [{:rtpmap, 0, "PCMU/8000"}]}])
  end

  defp register(service, ast, user, opts \\ []) do
    UAC.register(
      service,
      "sip:#{ast.host}:#{ast.sip_port}",
      opts ++ [:contact, from: aor(ast, user), to: aor(ast, user), password: ast.password]
    )
  end

  defp registered?(ast, user) do
    {:ok, contacts} = Asterisk.cli(ast, "pjsip show contacts")
    contacts =~ "#{user}/sip:#{user}@"
  end

  defp invite(service, ast, ip, from, to, opts \\ []) do
    UAC.invite(
      service,
      uri(ast, to),
      opts ++ [:auto_2xx_ack, from: aor(ast, from), password: ast.password, body: offer(ip)]
    )
  end

  # The next dialog-info NOTIFY (presence ones are skipped)
  defp next_dialog_info do
    assert_receive {FsUA1, {:notify, body}}, 5_000

    case DialogInfo.decode(body) do
      {:ok, doc} -> doc
      :error -> next_dialog_info()
    end
  end

  defp eventually_dialog_info(fun) do
    if not fun.(next_dialog_info().dialogs), do: eventually_dialog_info(fun)
  end

  defp hangup_all(ast), do: Asterisk.cli(ast, "channel request hangup all")

  describe "registrar" do
    test "register and unregister", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      assert {:ok, 200, []} = register(FsUA1, ast, 1000)
      eventually(fn -> registered?(ast, 1000) end)
      assert {:ok, 200, []} = register(FsUA1, ast, 1000, [:unregister])
      eventually(fn -> not registered?(ast, 1000) end)
    end

    test "SHA-256 (RFC 8760)", %{ast: ast, ip: ip} do
      # 1002 only accepts SHA-256
      start_ua(FsUA1, ip)
      parent = self()
      callback = fn {:req, req} -> send(parent, {:req, req}) end

      assert {:ok, 200, []} =
               register(FsUA1, ast, 1002, [:get_request, callback: callback])

      assert_receive {:req, %{headers: headers}}
      refute List.keymember?(headers, "authorization", 0)
      assert_receive {:req, req}
      assert [auth] = Caracola.Message.header(req, "authorization")
      assert {:ok, %{algorithm: :sha256}} = Caracola.Digest.parse(auth)
      eventually(fn -> registered?(ast, 1002) end)
      assert {:ok, 200, []} = register(FsUA1, ast, 1002, [:unregister])
    end

    test "wrong password", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      assert {:ok, code, []} = register(FsUA1, ast, 1002, password: "wrong")
      assert code in [401, 403]
    end
  end

  describe "applications" do
    test "echo: hold, DTMF over INFO and BYE", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      offer = offer(ip)

      assert {:ok, 200, [dialog: dialog, body: body]} =
               invite(FsUA1, ast, ip, 1000, 600, body: offer, get_meta: [:body])

      assert {:ok, %SDP{medias: [answer | _]}} = SDP.parse(body)
      assert answer.port > 0

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

    test "Asterisk hangs up", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      assert {:ok, 200, [dialog: _]} = invite(FsUA1, ast, ip, 1000, 601)
      hangup_all(ast)
      assert_receive {FsUA1, :bye}, 5_000
    end

    test "unknown extension and wrong password", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      assert {:ok, 404, []} = invite(FsUA1, ast, ip, 1000, 5555)
      assert {:ok, code, []} = invite(FsUA1, ast, ip, 1000, 600, password: "wrong")
      assert code in [401, 403]
    end
  end

  describe "through the Caracola B2BUA" do
    # FsUA1 calls Asterisk through B2B, that authenticates the B leg
    setup %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      start_ua(B2B, ip, target: uri(ast, 600), bridge_opts: [password: ast.password])
      %{b2b: "sip:600@#{ip}:#{port(B2B)}"}
    end

    defp b2b_invite(b2b, ast, ip, opts \\ []),
      do: UAC.invite(FsUA1, b2b, opts ++ [:auto_2xx_ack, from: aor(ast, 1000), body: offer(ip)])

    test "echo: hold, DTMF over INFO and BYE", %{ast: ast, ip: ip, b2b: b2b} do
      assert {:ok, 200, [dialog: dialog, body: body]} =
               b2b_invite(b2b, ast, ip, get_meta: [:body])

      assert {:ok, %SDP{medias: [answer | _]}} = SDP.parse(body)
      assert answer.port > 0
      assert_receive {:b2bua, :answered, _}

      assert {:ok, 200, [dialog: ^dialog, body: body]} =
               UAC.invite(dialog, [
                 :auto_2xx_ack,
                 body: SDP.update(offer(ip), :sendonly),
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

    test "Asterisk hangs up", %{ast: ast, ip: ip, b2b: b2b} do
      assert {:ok, 200, [dialog: _]} = b2b_invite(b2b, ast, ip)
      assert_receive {:b2bua, :answered, _}
      hangup_all(ast)
      assert_receive {:b2bua, {:stop, {:bye, :b}}, _}, 5_000
      assert_receive {FsUA1, :bye}, 5_000
    end
  end

  describe "Asterisk as B2BUA" do
    setup %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      assert {:ok, 200, []} = register(FsUA1, ast, 1000)
      :ok
    end

    test "call between registered users, hung up by both sides", %{ast: ast, ip: ip} do
      start_ua(FsUA2, ip)
      assert {:ok, 200, []} = register(FsUA2, ast, 1001)

      assert {:ok, 200, [dialog: dialog]} = invite(FsUA1, ast, ip, 1000, 1001)
      assert_receive {FsUA2, {:invite, _}}
      assert_receive {FsUA2, {:ack, _}}
      assert {:ok, 200, []} = UAC.bye(dialog)
      assert_receive {FsUA2, :bye}

      assert {:ok, 200, [dialog: _]} = invite(FsUA1, ast, ip, 1000, 1001)
      assert_receive {FsUA2, {:ack, dialog2}}
      assert {:ok, 200, []} = UAC.bye(dialog2)
      assert_receive {FsUA1, :bye}
    end

    test "asserted identity and privacy", %{ast: ast, ip: ip} do
      start_ua(FsUA2, ip)
      assert {:ok, 200, []} = register(FsUA2, ast, 1001)

      # Asserted by 1000 (trusted by Asterisk), with privacy
      assert {:ok, 200, [dialog: dialog]} =
               invite(FsUA1, ast, ip, 1000, 1001, [
                 {:add, "p-asserted-identity", "\"Alice\" <sip:5551234@#{ast.host}>"},
                 {:add, "privacy", "id"}
               ])

      assert_receive {FsUA2, {:invite_identity, from, [pai], privacy}}
      assert pai =~ "5551234"
      assert Enum.any?(privacy, &(&1 =~ "id"))
      assert from.user == "anonymous" or from.disp =~ "Anonymous"
      assert {:ok, 200, []} = UAC.bye(dialog)
      assert_receive {FsUA2, :bye}
    end

    test "busy", %{ast: ast, ip: ip} do
      start_ua(FsUA2, ip, busy: true)
      assert {:ok, 200, []} = register(FsUA2, ast, 1001)
      assert {:ok, 486, []} = invite(FsUA1, ast, ip, 1000, 1001)
    end

    test "cancel", %{ast: ast, ip: ip} do
      start_ua(FsUA2, ip, ring: true)
      assert {:ok, 200, []} = register(FsUA2, ast, 1001)
      parent = self()
      callback = fn {:resp, code, _} -> send(parent, {:resp, code}) end

      assert {:async, handle} =
               invite(FsUA1, ast, ip, 1000, 1001, [:async, callback: callback])

      assert_receive {FsUA2, {:invite, _}}
      assert_receive {:resp, 180}, 5_000
      assert :ok = UAC.cancel(handle)
      assert_receive {:resp, 487}, 5_000
      assert_receive {FsUA2, :cancel}, 5_000
    end

    test "blind transfer with REFER", %{ast: ast, ip: ip} do
      start_ua(FsUA2, ip)
      assert {:ok, 200, []} = register(FsUA2, ast, 1001)
      assert {:ok, 200, [dialog: dialog]} = invite(FsUA1, ast, ip, 1000, 1001)
      assert_receive {FsUA2, {:ack, _}}

      # 1000 transfers 1001 to the extension 601
      assert {:ok, 202, _} = UAC.refer(dialog, refer_to: aor(ast, 601), password: ast.password)
      assert_receive {FsUA1, {:notify, "SIP/2.0 100" <> _}}, 5_000
      assert_receive {FsUA1, {:notify, "SIP/2.0 200" <> _}}, 5_000

      # The transferor hangs up (RFC 5589)
      assert {:ok, 200, []} = UAC.bye(dialog)
      hangup_all(ast)
      assert_receive {FsUA2, :bye}, 5_000
    end
  end

  describe "attended transfer" do
    test "by Caracola, with Replaces", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      start_ua(FsUA2, ip)
      assert {:ok, 200, []} = register(FsUA1, ast, 1000)
      assert {:ok, 200, []} = register(FsUA2, ast, 1001)

      # 1000 talks to 1001, and consults the extension 601
      assert {:ok, 200, [dialog: d1]} = invite(FsUA1, ast, ip, 1000, 1001)
      assert_receive {FsUA2, {:ack, _}}
      assert {:ok, 200, [dialog: d2]} = invite(FsUA1, ast, ip, 1000, 601)

      # 1001 is transferred to 601, replacing the consultation call
      assert {:ok, refer_to} = Caracola.Replaces.refer_to("sip:601@#{ast.host}", d2)
      assert {:ok, 202, _} = UAC.refer(d1, refer_to: refer_to, password: ast.password)
      assert_receive {FsUA1, {:notify, "SIP/2.0 200" <> _}}, 5_000
      assert_receive {FsUA1, :bye}, 5_000

      # The transferor hangs up; 1001 stays connected until Asterisk hangs up
      assert {:ok, 200, []} = UAC.bye(d1)
      refute_received {FsUA2, :bye}
      hangup_all(ast)
      assert_receive {FsUA2, :bye}, 5_000
    end
  end

  describe "events and calls from Asterisk" do
    test "message waiting subscription", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      assert {:ok, 200, []} = register(FsUA1, ast, 1000)

      assert {:ok, 200, [subscription: subs]} =
               UAC.subscribe(FsUA1, uri(ast, 1000),
                 event: "message-summary",
                 from: aor(ast, 1000),
                 password: ast.password
               )

      assert_receive {FsUA1, {:notify, body}}, 5_000
      assert {:ok, %{waiting: false}} = MessageWaiting.decode(body)

      # While subscribed, Asterisk sends no unsolicited NOTIFYs to 1000
      # (mwi_subscribe_replaces_unsolicited)
      assert {:ok, 200, _} = UAC.subscribe(subs, expires: 0, password: ast.password)
    end

    test "dialog state and presence (BLF)", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      start_ua(FsUA2, ip)
      assert {:ok, 200, []} = register(FsUA1, ast, 1000)
      assert {:ok, 200, []} = register(FsUA2, ast, 1001)

      # 1000 watches the hint of 1001
      assert {:ok, 200, [subscription: dialog_subs]} =
               UAC.subscribe(FsUA1, uri(ast, 1001), [
                 {:add, "accept", DialogInfo.content_type()},
                 event: "dialog",
                 from: aor(ast, 1000),
                 password: ast.password
               ])

      assert %{dialogs: dialogs} = next_dialog_info()
      assert Enum.all?(dialogs, &(&1.state == :terminated))

      assert {:ok, 200, [subscription: presence_subs]} =
               UAC.subscribe(FsUA1, uri(ast, 1001), [
                 {:add, "accept", Presence.content_type()},
                 event: "presence",
                 from: aor(ast, 1000),
                 password: ast.password
               ])

      assert_receive {FsUA1, {:notify, "<?xml" <> _ = body}}, 5_000
      assert {:ok, %{entity: entity, tuples: [%{status: :open} | _]}} = Presence.decode(body)
      assert entity =~ "1001@"

      # A call to 1001 is confirmed, and then terminated
      assert {:ok, 200, [dialog: dialog]} = invite(FsUA1, ast, ip, 1000, 1001)
      eventually_dialog_info(fn dialogs -> Enum.any?(dialogs, &(&1.state == :confirmed)) end)
      assert {:ok, 200, []} = UAC.bye(dialog)
      eventually_dialog_info(fn dialogs -> Enum.all?(dialogs, &(&1.state == :terminated)) end)

      assert {:ok, 200, _} = UAC.subscribe(dialog_subs, expires: 0, password: ast.password)
      assert {:ok, 200, _} = UAC.subscribe(presence_subs, expires: 0, password: ast.password)
    end

    test "unsolicited message waiting", %{ast: ast, ip: ip} do
      # Sent by Asterisk when 1000 registers
      start_ua(FsUA1, ip)
      assert {:ok, 200, []} = register(FsUA1, ast, 1000)
      assert_receive {FsUA1, {:unsolicited_notify, body}}, 5_000
      assert {:ok, %{waiting: false}} = MessageWaiting.decode(body)
    end

    test "originate and hang up", %{ast: ast, ip: ip} do
      start_ua(FsUA1, ip)
      [%{local_port: port} | _] = Caracola.listeners(FsUA1)

      assert {:ok, [{"Response", "Success"} | _]} =
               Asterisk.ami(ast, [
                 {"Action", "Originate"},
                 {"Channel", "PJSIP/malla/sip:test@#{ip}:#{port}"},
                 {"Application", "Wait"},
                 {"Data", "30"},
                 {"Async", "true"}
               ])

      assert_receive {FsUA1, {:invite, _}}, 5_000
      assert_receive {FsUA1, {:ack, _}}, 5_000
      hangup_all(ast)
      assert_receive {FsUA1, :bye}, 5_000
    end
  end

  describe "Asterisk as a trunk of a Caracola proxy" do
    setup %{ast: ast, ip: ip, proxy_port: proxy_port} do
      # Only SHA-256: Asterisk and 1000 answer it
      start_service(BsProxy,
        sip: [listen: "sip:#{ip}:#{proxy_port}", digest_algorithms: [:sha256]]
      )

      wait_trunk(100)
      start_ua(FsUA1, ip)
      proxy = "sip:#{ip}:#{proxy_port}"

      # 1000 registers in the proxy too
      assert {:ok, 200, []} =
               UAC.register(FsUA1, proxy, [
                 :contact,
                 from: "sip:1000@malla.test",
                 to: "sip:1000@malla.test",
                 password: ast.password
               ])

      %{route: "<#{proxy};lr>"}
    end

    test "calls to Asterisk through the proxy", %{ast: ast, ip: ip, route: route} do
      assert {:ok, 200, [dialog: dialog]} =
               UAC.invite(FsUA1, "sip:asterisk@malla.test", [
                 :auto_2xx_ack,
                 route: route,
                 from: "sip:1000@malla.test",
                 password: ast.password,
                 body: offer(ip)
               ])

      assert {:ok, 200, []} = UAC.bye(dialog)
    end

    test "calls from Asterisk through the proxy", %{ast: ast} do
      assert {:ok, [{"Response", "Success"} | _]} =
               Asterisk.ami(ast, [
                 {"Action", "Originate"},
                 {"Channel", "PJSIP/malla-trunk/sip:1000@malla.test"},
                 {"Application", "Wait"},
                 {"Data", "30"},
                 {"Async", "true"}
               ])

      assert_receive {FsUA1, {:invite, _}}, 5_000
      assert_receive {FsUA1, {:ack, dialog}}, 5_000

      # The INVITE was larger than the UDP limit, so the proxy sent it over
      # TCP (RFC 3261 §18.1.1): the BYE does not come from the registered
      # origin, and is challenged
      assert {:ok, 200, []} = UAC.bye(dialog, password: ast.password)
    end
  end

  # Asterisk retries its registration every second
  defp wait_trunk(0), do: flunk("Asterisk did not register")

  defp wait_trunk(retries) do
    if Registrar.find(BsProxy, :sip, "asterisk", "malla.test") == [] do
      Process.sleep(100)
      wait_trunk(retries - 1)
    end
  end
end
