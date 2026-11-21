defmodule Caracola.DNSTest do
  use ExUnit.Case, async: true

  alias Caracola.DNS

  doctest Caracola.DNS

  # Fake resolver with the records of nkpacket's dns_test
  defmodule FakeResolver do
    @behaviour Caracola.DNS.Resolver

    @naptr %{
      "test.local" => [
        {1, 1, "s", "sips+d2t", "", "_sips._tcp.test1.local"},
        {1, 2, "s", "sip+d2t", "", "_sip._tcp.test2.local"},
        {2, 1, "s", "sip+d2t", "", "_sip._tcp.test3.local"},
        {2, 2, "S", "SIP+D2U", "", "_sip._udp.test4.local"},
        {3, 1, "u", "sip+d2u", "!^.*$!sip:x@y!", ""},
        {3, 2, "s", "unknown", "", "_x._y.test5.local"}
      ],
      "sip2sip.info" => [
        {30, 100, "s", "sip+d2u", "", "_sip._udp.sip2sip.info"},
        {5, 100, "s", "sips+d2t", "", "_sips._tcp.sip2sip.info"},
        {10, 100, "s", "sip+d2t", "", "_sip._tcp.sip2sip.info"}
      ]
    }

    @srv %{
      "_sips._tcp.test1.local" => [{1, 1, 100, "test100.local"}],
      "_sip._tcp.test2.local" => [
        {1, 1, 200, "test200.local"},
        {2, 1, 201, "test201.local"},
        {2, 5, 202, "test202.local"},
        {3, 1, 300, "test300.local"}
      ],
      "_sip._tcp.test3.local" => [{1, 1, 400, "test400.local"}],
      "_sip._udp.test4.local" => [{1, 1, 500, "test500.local"}],
      "_sips._tcp.sip2sip.info" => [{100, 100, 443, "proxy.sipthor.net"}],
      "_sip._tcp.sip2sip.info" => [{100, 100, 5060, "proxy.sipthor.net"}],
      "_sip._udp.sip2sip.info" => [{100, 100, 5060, "proxy.sipthor.net"}],
      "_sip._tcp.srvonly.local" => [{1, 1, 5070, "test500.local"}],
      "_sips._tcp.srvonly.local" => [{1, 1, 5071, "test500.local"}]
    }

    @ips %{
      "test100.local" => [{1, 1, 100, 1}, {1, 1, 100, 2}],
      "test200.local" => [{1, 1, 200, 1}],
      "test201.local" => [{1, 1, 201, 1}],
      "test202.local" => [{1, 1, 202, 1}],
      "test300.local" => [{1, 1, 300, 1}],
      "test500.local" => [{1, 1, 500, 1}],
      "proxy.sipthor.net" => [{81, 23, 228, 129}, {85, 17, 186, 7}, {81, 23, 228, 150}],
      "plain.local" => [{9, 9, 9, 9}]
    }

    @impl true
    def naptr(domain), do: Map.get(@naptr, domain, [])
    @impl true
    def srv(domain), do: Map.get(@srv, domain, [])
    @impl true
    def ips(host), do: Map.get(@ips, host, [])
  end

  @opts [resolver: FakeResolver, cache: false]

  test "uris (from nkpacket dns_test)" do
    for {uri, result} <- [
          {"<sip:1.2.3.4;transport=udp>", {:ok, [{:udp, {1, 2, 3, 4}, 5060}]}},
          {"<sip:1.2.3.4;transport=tcp>", {:ok, [{:tcp, {1, 2, 3, 4}, 5060}]}},
          {"<sip:1.2.3.4;transport=tls>", {:ok, [{:tls, {1, 2, 3, 4}, 5061}]}},
          {"<sip:1.2.3.4;transport=sctp>", {:ok, [{:sctp, {1, 2, 3, 4}, 5060}]}},
          {"<sip:1.2.3.4;transport=ws>", {:ok, [{:ws, {1, 2, 3, 4}, 80}]}},
          {"<sip:1.2.3.4;transport=wss>", {:ok, [{:wss, {1, 2, 3, 4}, 443}]}},
          {"<sip:1.2.3.4;transport=TCP>", {:ok, [{:tcp, {1, 2, 3, 4}, 5060}]}},
          {"<sip:1.2.3.4;transport=other>", {:error, {:invalid_transport, "other"}}},
          {"<sips:1.2.3.4;transport=udp>", {:error, {:invalid_transport, :udp}}},
          {"<sips:1.2.3.4;transport=tcp>", {:ok, [{:tls, {1, 2, 3, 4}, 5061}]}},
          {"<sips:1.2.3.4;transport=tls>", {:ok, [{:tls, {1, 2, 3, 4}, 5061}]}},
          {"<sips:1.2.3.4;transport=sctp>", {:error, {:invalid_transport, :sctp}}},
          {"<sips:1.2.3.4;transport=ws>", {:ok, [{:wss, {1, 2, 3, 4}, 443}]}},
          {"<sips:1.2.3.4;transport=wss>", {:ok, [{:wss, {1, 2, 3, 4}, 443}]}},
          {"<sip:1.2.3.4:4321;transport=tcp>", {:ok, [{:tcp, {1, 2, 3, 4}, 4321}]}},
          {"<sips:127.0.0.1:4321;transport=tls>", {:ok, [{:tls, {127, 0, 0, 1}, 4321}]}},
          {"<sip:1.2.3.4>", {:ok, [{:udp, {1, 2, 3, 4}, 5060}]}},
          {"<sip:1.2.3.4:4321>", {:ok, [{:udp, {1, 2, 3, 4}, 4321}]}},
          {"<sips:1.2.3.4>", {:ok, [{:tls, {1, 2, 3, 4}, 5061}]}},
          {"<sips:1.2.3.4:4321>", {:ok, [{:tls, {1, 2, 3, 4}, 4321}]}},
          {"<sip:[1::5]>", {:ok, [{:udp, {1, 0, 0, 0, 0, 0, 0, 5}, 5060}]}},
          {"sip:x@plain.local;transport=tcp", {:ok, [{:tcp, {9, 9, 9, 9}, 5060}]}},
          {"<sip:x@plain.local;maddr=1.2.3.4>", {:ok, [{:udp, {1, 2, 3, 4}, 5060}]}},
          {"<sip:all>", {:ok, [{:udp, {0, 0, 0, 0}, 5060}]}},
          {"<sips:all>", {:ok, [{:tls, {0, 0, 0, 0}, 5061}]}},
          {"<sip:all6:5070>", {:ok, [{:udp, {0, 0, 0, 0, 0, 0, 0, 0}, 5070}]}},
          {"tel:+1234", {:error, {:invalid_scheme, :tel}}},
          {"<sip:a", {:error, {:invalid_uri, "<sip:a"}}}
        ] do
      assert DNS.resolve(uri, @opts) == result, "for #{uri}"
    end
  end

  test "naptr and srv (resolv1 from nkpacket dns_test)" do
    assert {:ok, [a, b, c, d, e, f, g]} = DNS.resolve("sip:test.local", @opts)

    assert Enum.sort([a, b]) == [{:tls, {1, 1, 100, 1}, 100}, {:tls, {1, 1, 100, 2}, 100}]
    assert c == {:tcp, {1, 1, 200, 1}, 200}
    assert Enum.sort([d, e]) == [{:tcp, {1, 1, 201, 1}, 201}, {:tcp, {1, 1, 202, 1}, 202}]
    assert f == {:tcp, {1, 1, 300, 1}, 300}
    # test400.local has no addresses
    assert g == {:udp, {1, 1, 500, 1}, 500}

    # SIPS only uses sips services
    assert {:ok, [h, i]} = DNS.resolve("sips:test.local", @opts)
    assert Enum.sort([h, i]) == [{:tls, {1, 1, 100, 1}, 100}, {:tls, {1, 1, 100, 2}, 100}]
  end

  test "naptr ordering (resolv2 from nkpacket dns_test)" do
    ips = Enum.sort([{81, 23, 228, 129}, {85, 17, 186, 7}, {81, 23, 228, 150}])
    assert {:ok, targets} = DNS.resolve("sip:sip2sip.info", @opts)

    assert [{:tls, _, 443}, {:tls, _, 443}, {:tls, _, 443}] = Enum.slice(targets, 0..2)
    assert [{:tcp, _, 5060}, {:tcp, _, 5060}, {:tcp, _, 5060}] = Enum.slice(targets, 3..5)
    assert [{:udp, _, 5060}, {:udp, _, 5060}, {:udp, _, 5060}] = Enum.slice(targets, 6..8)

    for group <- Enum.chunk_every(targets, 3),
        do: assert(Enum.sort(for {_, ip, _} <- group, do: ip) == ips)

    assert {:ok, [{:udp, _, 0}, _, _]} =
             DNS.resolve("sip:proxy.sipthor.net", [listen: true] ++ @opts)
  end

  test "srv without naptr, transport without port, and a records" do
    assert DNS.resolve("sip:srvonly.local", @opts) ==
             {:ok, [{:tcp, {1, 1, 500, 1}, 5070}, {:tls, {1, 1, 500, 1}, 5071}]}

    assert DNS.resolve("sips:srvonly.local", @opts) == {:ok, [{:tls, {1, 1, 500, 1}, 5071}]}

    assert DNS.resolve("<sip:srvonly.local;transport=tcp>", @opts) ==
             {:ok, [{:tcp, {1, 1, 500, 1}, 5070}]}

    assert DNS.resolve("<sip:srvonly.local;transport=udp>", @opts) == {:ok, []}
    assert DNS.resolve("sip:plain.local", @opts) == {:ok, [{:udp, {9, 9, 9, 9}, 5060}]}
    assert DNS.resolve("sips:plain.local", @opts) == {:ok, [{:tls, {9, 9, 9, 9}, 5061}]}

    assert DNS.resolve("<sip:plain.local;transport=ws>", @opts) ==
             {:ok, [{:ws, {9, 9, 9, 9}, 80}]}
  end

  test "system resolver" do
    assert {:ok, [{:udp, {127, 0, 0, 1}, 5070} | _]} =
             DNS.resolve("sip:localhost:5070", cache: false)
  end

  test "cache" do
    defmodule CountingResolver do
      @behaviour Caracola.DNS.Resolver
      @impl true
      def naptr(_), do: []
      @impl true
      def srv(_), do: []
      @impl true
      def ips(host) do
        send(self(), {:lookup, host})
        [{1, 2, 3, 4}]
      end
    end

    host = "cached-#{System.unique_integer([:positive])}.local"
    opts = [resolver: CountingResolver]
    assert {:ok, [{:udp, {1, 2, 3, 4}, 5060}]} = DNS.resolve("sip:#{host}:5060", opts)
    assert {:ok, [{:udp, {1, 2, 3, 4}, 5060}]} = DNS.resolve("sip:#{host}:5060", opts)
    assert_received {:lookup, ^host}
    refute_received {:lookup, ^host}
  end

  test "rfc 2782 ordering (weight from nkpacket_dns)" do
    assert DNS.sort_srv([]) == []
    assert DNS.sort_srv([{1, 1, :a}]) == [:a]
    assert DNS.sort_srv([{2, 2, :a}, {1, 1, :b}, {3, 3, :c}]) == [:b, :a, :c]
    assert [:b, x, y, :c] = DNS.sort_srv([{2, 10, :a}, {1, 1, :b}, {3, 3, :c}, {2, 10, :d}])
    assert Enum.sort([x, y]) == [:a, :d]

    firsts =
      for _ <- 1..2000 do
        [first | _] = order = DNS.sort_srv([{1, 1, :a}, {1, 9, :b}, {1, 90, :c}])
        assert Enum.sort(order) == [:a, :b, :c]
        first
      end

    freq = Enum.frequencies(firsts)
    assert freq[:c] > freq[:b] and freq[:b] > freq[:a]

    # Weight 0 entries are still included
    assert Enum.sort(DNS.sort_srv([{1, 0, :a}, {1, 0, :b}, {1, 5, :c}])) == [:a, :b, :c]
  end
end
