defmodule Caracola.TransportTest do
  use ExUnit.Case, async: true

  alias Caracola.{Message, Transport}
  alias Caracola.Transport.Port

  @localhost {127, 0, 0, 1}

  # Ported and adapted from nkpacket's udp_test and tcp_test

  defp options(id, body \\ "") do
    "OPTIONS sip:b@127.0.0.1 SIP/2.0\r\n" <>
      "Via: SIP/2.0/UDP 127.0.0.1;branch=z9hG4bK#{id}\r\n" <>
      "From: <sip:a@a>;tag=1\r\nTo: <sip:b@b>\r\nCall-ID: #{id}\r\nCSeq: 1 OPTIONS\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
  end

  defp service, do: {:test, System.unique_integer([:positive])}

  defp listen(service, transport, opts \\ []) do
    opts = Keyword.merge([ip: @localhost, port: 0, handler: {Caracola.TestHandler, self()}], opts)
    {:ok, pid} = Transport.start_listener(service, transport, opts)
    on_exit(fn -> Transport.stop_listener(pid) end)
    ports = Transport.listener_ports(pid)
    %Port{local_port: port} = Enum.find(ports, &(&1.transport == transport))
    {pid, port}
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> :ok
      retries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  describe "udp" do
    test "listener, receive, reply and errors" do
      svc = service()
      {pid, port} = listen(svc, :udp)

      # UDP listeners also listen on TCP, on the same port
      assert [
               %Port{
                 transport: :tcp,
                 local_ip: @localhost,
                 local_port: ^port,
                 listen_port: ^port
               },
               %Port{
                 transport: :udp,
                 local_ip: @localhost,
                 local_port: ^port,
                 listen_port: ^port,
                 remote_ip: nil
               }
             ] = Transport.listeners(svc)

      assert [%Port{transport: :udp}] = Transport.listeners(svc, :udp)

      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_, client_port}} = :inet.sockname(socket)

      :ok = :gen_udp.send(socket, @localhost, port, options("u1"))

      assert_receive {:sip,
                      %Port{transport: :udp, remote_ip: @localhost, remote_port: ^client_port} =
                        from, %Message{call_id: "u1"}}

      # Replies come from the listening port
      assert {:ok, ^from} = Transport.send(from, "reply")
      assert {:ok, {@localhost, ^port, "reply"}} = :gen_udp.recv(socket, 0, 1000)

      # Invalid requests get a 400
      :ok =
        :gen_udp.send(
          socket,
          @localhost,
          port,
          "OPTIONS sip:a SIP/2.0\r\nVia: SIP/2.0/UDP h\r\n\r\n"
        )

      assert {:ok, {@localhost, ^port, "SIP/2.0 400 Invalid Call-ID\r\n" <> _}} =
               :gen_udp.recv(socket, 0, 1000)

      # Keepalives and garbage are ignored
      :ok = :gen_udp.send(socket, @localhost, port, "\r\n\r\n")
      :ok = :gen_udp.send(socket, @localhost, port, "garbage")
      refute_receive {:sip, _, _}, 100

      # Registry entries are removed asynchronously
      :ok = Transport.stop_listener(pid)
      eventually(fn -> Transport.listeners(svc) == [] end)
    end

    test "send between services, size limits and missing listeners" do
      {svc_a, svc_b} = {service(), service()}
      {_, port_a} = listen(svc_a, :udp)
      {_, port_b} = listen(svc_b, :udp)

      assert {:ok, %Port{transport: :udp, local_port: ^port_a, remote_port: ^port_b}} =
               Transport.send(svc_a, "sip:127.0.0.1:#{port_b}", options("u2"))

      assert_receive {:sip, %Port{remote_port: ^port_a}, %Message{call_id: "u2"}}

      # A %Message{} can be sent too
      {:ok, msg, ""} = Caracola.Parser.parse(options("u3"))
      assert {:ok, _} = Transport.send(svc_a, {:udp, @localhost, port_b}, msg)
      assert_receive {:sip, _, ^msg}

      large = options("u4", String.duplicate("x", 2000))

      assert Transport.send(svc_a, {:udp, @localhost, port_b}, large, udp_max_size: 1300) ==
               {:error, :udp_too_large}

      assert {:ok, %Port{transport: :tcp, remote_port: ^port_b}} =
               Transport.send(svc_a, {:udp, @localhost, port_b}, large,
                 udp_max_size: 1300,
                 udp_to_tcp: true
               )

      assert_receive {:sip, %Port{transport: :tcp}, %Message{call_id: "u4"}}

      assert Transport.send(service(), "sip:127.0.0.1:5", options("x")) ==
               {:error, :no_listening_transport}

      assert Transport.send(svc_a, "<sip:127.0.0.1:5;transport=tls>", options("x")) ==
               {:error, :no_listening_transport}

      assert Transport.send(svc_a, "sip:[::1]:5", options("x")) ==
               {:error, :no_listening_transport}

      assert Transport.send(svc_a, "<sip:a", options("x")) == {:error, {:invalid_uri, "<sip:a"}}
      assert Transport.send(svc_a, "tel:1", options("x")) == {:error, {:invalid_scheme, :tel}}
    end

    test "udp and tcp are restarted together" do
      svc = service()
      {pid, port} = listen(svc, :udp, port: 0)

      [%Port{transport: :tcp, pid: tcp_pid}, %Port{transport: :udp, pid: udp_pid}] =
        Transport.listeners(svc)

      # The TCP listener is stopped and started again with the UDP one
      Process.exit(udp_pid, :kill)

      eventually(fn ->
        match?(
          [
            %Port{transport: :tcp, local_port: ^port, pid: new_tcp},
            %Port{transport: :udp, local_port: ^port, pid: new_udp}
          ]
          when new_udp != udp_pid and new_tcp != tcp_pid,
          Transport.listeners(svc)
        )
      end)

      assert Process.alive?(pid)
    end
  end

  describe "tcp" do
    test "connections are registered, reused and replied to" do
      {svc_a, svc_b} = {service(), service()}
      {_, port_a} = listen(svc_a, :tcp)
      {_, port_b} = listen(svc_b, :tcp)

      assert {:ok,
              %Port{
                transport: :tcp,
                pid: conn_a,
                local_port: local_a,
                remote_port: ^port_b,
                listen_port: ^port_a
              } = a} =
               Transport.send(svc_a, "<sip:127.0.0.1:#{port_b};transport=tcp>", options("t1"))

      assert_receive {:sip,
                      %Port{
                        transport: :tcp,
                        remote_port: ^local_a,
                        local_port: ^port_b,
                        listen_port: ^port_b
                      } = b, %Message{call_id: "t1"}}

      assert [^a] = Transport.connections(svc_a)
      assert [^b] = Transport.connections(svc_b)
      assert Transport.get_connected(svc_a, :tcp, @localhost, port_b) == [a]

      # The connection is reused
      assert {:ok, %Port{pid: ^conn_a}} =
               Transport.send(svc_a, {:tcp, @localhost, port_b}, options("t2"))

      assert_receive {:sip, ^b, %Message{call_id: "t2"}}

      # Replies go back through the same connection
      assert {:ok, ^b} = Transport.send(b, options("t3"))
      assert_receive {:sip, ^a, %Message{call_id: "t3"}}

      # A new connection can be forced, but it is not shared
      assert {:ok, %Port{pid: conn_a2}} =
               Transport.send(svc_a, {:tcp, @localhost, port_b}, options("t4"),
                 new_connection: true
               )

      assert conn_a2 != conn_a
      assert_receive {:sip, %Port{pid: conn_b2}, %Message{call_id: "t4"}} when conn_b2 != b.pid
      assert length(Transport.connections(svc_a)) == 2
      assert Transport.get_connected(svc_a, :tcp, @localhost, port_b) == [a]
    end

    test "concurrent senders share one connection" do
      {svc_a, svc_b} = {service(), service()}
      listen(svc_a, :tcp)
      {_, port_b} = listen(svc_b, :tcp)

      pids =
        1..20
        |> Task.async_stream(fn n ->
          Transport.send(svc_a, {:tcp, @localhost, port_b}, options("c#{n}"))
        end)
        |> Enum.map(fn {:ok, {:ok, %Port{pid: pid}}} -> pid end)
        |> Enum.uniq()

      assert length(pids) == 1
      for _ <- 1..20, do: assert_receive({:sip, _, %Message{call_id: "c" <> _}})
    end

    test "idle connections are closed on both sides" do
      {svc_a, svc_b} = {service(), service()}
      listen(svc_a, :tcp)
      {_, port_b} = listen(svc_b, :tcp)

      assert {:ok, %Port{pid: conn}} =
               Transport.send(svc_a, {:tcp, @localhost, port_b}, options("i1"), idle_timeout: 100)

      assert_receive {:sip, _, _}
      ref = Process.monitor(conn)
      assert_receive {:DOWN, ^ref, _, _, :normal}, 1000

      eventually(fn ->
        Transport.connections(svc_a) == [] and Transport.connections(svc_b) == []
      end)
    end

    test "framing, keepalives and invalid messages" do
      svc = service()
      {_, port} = listen(svc, :tcp)
      {:ok, socket} = :gen_tcp.connect(@localhost, port, [:binary, active: false])

      # Two messages at once, and one split in parts
      :ok = :gen_tcp.send(socket, options("f1") <> options("f2", "body"))
      <<part1::binary-size(30), part2::binary>> = options("f3", "abc")
      :ok = :gen_tcp.send(socket, part1)
      Process.sleep(20)
      :ok = :gen_tcp.send(socket, part2)

      assert_receive {:sip, _, %Message{call_id: "f1"}}
      assert_receive {:sip, _, %Message{call_id: "f2", body: "body"}}
      assert_receive {:sip, _, %Message{call_id: "f3", body: "abc"}}

      # RFC 5626 ping and pong
      :ok = :gen_tcp.send(socket, "\r\n\r\n")
      assert {:ok, "\r\n"} = :gen_tcp.recv(socket, 0, 1000)
      :ok = :gen_tcp.send(socket, "\r\n")
      refute_receive {:sip, _, _}, 50

      # Content-Length is mandatory: 400 and the connection is closed
      :ok =
        :gen_tcp.send(socket, "OPTIONS sip:a SIP/2.0\r\nVia: SIP/2.0/TCP h\r\nCall-ID: 1\r\n\r\n")

      assert {:ok, "SIP/2.0 400 Invalid Content-Length\r\n" <> _} = :gen_tcp.recv(socket, 0, 1000)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
    end
  end

  describe "tls" do
    setup do
      # RSA and SHA-256, as TLS 1.3 requires
      opts = [key: {:rsa, 2048, 65_537}, digest: :sha256]
      chain = %{root: opts, intermediates: [], peer: opts}

      %{server_config: server, client_config: client} =
        :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

      %{server: server, client: Keyword.take(client, [:cacerts])}
    end

    test "send and reuse", %{server: server, client: client} do
      {svc_a, svc_b} = {service(), service()}
      {_, port_a} = listen(svc_a, :tls, tls: server)
      {_, port_b} = listen(svc_b, :tls, tls: server)

      assert {:ok, %Port{transport: :tls, pid: conn, remote_port: ^port_b, listen_port: ^port_a}} =
               Transport.send(svc_a, "<sips:127.0.0.1:#{port_b}>", options("s1"), tls: client)

      assert_receive {:sip, %Port{transport: :tls} = b, %Message{call_id: "s1"}}

      assert {:ok, %Port{pid: ^conn}} =
               Transport.send(svc_a, "<sip:127.0.0.1:#{port_b};transport=tls>", options("s2"),
                 tls: client
               )

      assert_receive {:sip, ^b, %Message{call_id: "s2"}}

      assert {:ok, _} = Transport.send(b, options("s3"))
      assert_receive {:sip, %Port{pid: ^conn}, %Message{call_id: "s3"}}
    end

    test "the server certificate is verified", %{server: server} do
      {svc_a, svc_b} = {service(), service()}
      listen(svc_a, :tls, tls: server)
      {_, port_b} = listen(svc_b, :tls, tls: server)

      # Not signed by a system CA
      assert {:error, {:tls_alert, _}} =
               Transport.send(svc_a, {:tls, @localhost, port_b}, options("v1"))

      refute_receive {:sip, _, _}, 50
      assert Transport.connections(svc_a) == []
    end
  end

  describe "ws" do
    # Raw WebSocket client: handshake and masked frames
    defp ws_connect(port, headers \\ "Sec-WebSocket-Protocol: sip\r\n", path \\ "/") do
      {:ok, socket} = :gen_tcp.connect(@localhost, port, [:binary, active: false])

      :ok =
        :gen_tcp.send(
          socket,
          "GET #{path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" <>
            "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" <>
            "Sec-WebSocket-Version: 13\r\n" <> headers <> "\r\n"
        )

      {:ok, response} = :gen_tcp.recv(socket, 0, 1000)
      {socket, response}
    end

    defp ws_frame(fin, opcode, data) do
      key = <<1, 2, 3, 4>>
      size = byte_size(data)
      masked = :crypto.exor(data, binary_part(:binary.copy(key, div(size, 4) + 1), 0, size))
      <<fin::1, 0::3, opcode::4, 1::1, size::7, key::binary, masked::binary>>
    end

    test "send, reuse and reply" do
      {svc_a, svc_b} = {service(), service()}
      {_, port_a} = listen(svc_a, :ws)
      {_, port_b} = listen(svc_b, :ws, path: "/sip")

      assert {:ok, %Port{transport: :ws, pid: conn, remote_port: ^port_b, listen_port: ^port_a}} =
               Transport.send(svc_a, "<sip:127.0.0.1:#{port_b}/sip;transport=ws>", options("w1"))

      assert_receive {:sip, %Port{transport: :ws} = b, %Message{call_id: "w1"}}

      # The connection is reused, and works in both directions
      assert {:ok, %Port{pid: ^conn}} =
               Transport.send(svc_a, {:ws, @localhost, port_b}, options("w2"))

      assert_receive {:sip, ^b, %Message{call_id: "w2"}}

      # Larger than 125 and 65535 bytes
      body = String.duplicate("a", 70_000)
      assert {:ok, _} = Transport.send(b, options("w3", body))
      assert_receive {:sip, %Port{pid: ^conn}, %Message{call_id: "w3", body: ^body}}
      assert [%Port{transport: :ws}] = Transport.connections(svc_b)
    end

    test "wss", %{} do
      opts = [key: {:rsa, 2048, 65_537}, digest: :sha256]
      chain = %{root: opts, intermediates: [], peer: opts}

      %{server_config: server, client_config: client} =
        :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

      {svc_a, svc_b} = {service(), service()}
      listen(svc_a, :wss, tls: server)
      {_, port_b} = listen(svc_b, :wss, tls: server)

      assert {:ok, %Port{transport: :wss, pid: conn}} =
               Transport.send(svc_a, "<sips:127.0.0.1:#{port_b};transport=ws>", options("s1"),
                 tls: Keyword.take(client, [:cacerts])
               )

      assert_receive {:sip, %Port{transport: :wss} = b, %Message{call_id: "s1"}}
      assert {:ok, _} = Transport.send(b, options("s2"))
      assert_receive {:sip, %Port{pid: ^conn}, %Message{call_id: "s2"}}
    end

    test "handshake" do
      svc = service()
      {_, port} = listen(svc, :ws, path: "/sip")

      # Without the sip subprotocol
      {_, response} = ws_connect(port, "", "/sip")
      assert response =~ ~r/^HTTP\/1.1 400/
      # Another path
      {_, response} = ws_connect(port, "Sec-WebSocket-Protocol: sip\r\n", "/other")
      assert response =~ ~r/^HTTP\/1.1 404/

      {socket, response} = ws_connect(port, "Sec-WebSocket-Protocol: chat, sip\r\n", "/sip?a=1")
      assert response =~ ~r/^HTTP\/1.1 101/
      # RFC 6455 §1.3 example
      assert response =~ "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"

      assert response =~ "Sec-WebSocket-Protocol: sip\r\n"

      # Fragmented message, with a ping in the middle
      <<part1::binary-50, part2::binary>> = options("f1")
      :ok = :gen_tcp.send(socket, ws_frame(0, 1, part1) <> ws_frame(1, 9, "hi"))
      assert {:ok, <<1::1, 0::3, 10::4, 0::1, 2::7, "hi">>} = :gen_tcp.recv(socket, 0, 1000)
      :ok = :gen_tcp.send(socket, ws_frame(1, 0, part2))
      assert_receive {:sip, %Port{transport: :ws}, %Message{call_id: "f1"}}

      # Invalid SIP message: 400 and the connection stays open
      :ok =
        :gen_tcp.send(
          socket,
          ws_frame(1, 1, "OPTIONS sip:a SIP/2.0\r\nVia: SIP/2.0/WS h\r\n\r\n")
        )

      assert {:ok, <<1::1, 0::3, 1::4, 0::1, _::7, "SIP/2.0 400" <> _>>} =
               :gen_tcp.recv(socket, 0, 1000)

      # Unmasked frames from a client close the connection
      :ok = :gen_tcp.send(socket, <<1::1, 0::3, 1::4, 0::1, 2::7, "ab">>)
      assert {:ok, <<1::1, 0::3, 8::4, 0::1, 2::7, 1002::16>>} = :gen_tcp.recv(socket, 0, 1000)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
    end

    test "close" do
      svc = service()
      {_, port} = listen(svc, :ws)
      {socket, _} = ws_connect(port)
      eventually(fn -> Transport.connections(svc) != [] end)
      :ok = :gen_tcp.send(socket, ws_frame(1, 8, <<1000::16>>))
      assert {:ok, <<1::1, 0::3, 8::4, 0::1, 2::7, 1000::16>>} = :gen_tcp.recv(socket, 0, 1000)
      eventually(fn -> Transport.connections(svc) == [] end)
    end
  end
end
