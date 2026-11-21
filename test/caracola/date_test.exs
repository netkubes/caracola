defmodule Caracola.DateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Caracola.Date, as: SipDate

  doctest Caracola.Date

  test "parse" do
    assert SipDate.parse("  13 Nov 2010 23:29:00 GMT ") == {:ok, ~U[2010-11-13 23:29:00Z]}
    assert SipDate.parse("Thu, 01 Jan 1970 00:00:00 GMT") == {:ok, ~U[1970-01-01 00:00:00Z]}
    assert SipDate.parse("Sat, 1 Jan 2000 00:00:00 GMT") == {:ok, ~U[2000-01-01 00:00:00Z]}

    for bad <- [
          "",
          "Sat, 13 Nov 2010 23:29:00",
          "Sat, 13 Nov 2010 23:29:00 UTC",
          "Sun, 13 Nov 2010 23:29:00 GMT",
          "Sat, 31 Nov 2010 23:29:00 GMT",
          "Sat, 13 Foo 2010 23:29:00 GMT",
          "Sat, 13 Nov 2010 24:29:00 GMT",
          "Sat, 13 Nov 2010 23:29 GMT",
          "Sat 13 Nov 2010 23:29:00 GMT"
        ] do
      assert SipDate.parse(bad) == :error, "expected error for #{inspect(bad)}"
    end
  end

  test "encode shifts to GMT" do
    {:ok, dt} = DateTime.new(~D[2024-02-29], ~T[01:02:03], "Etc/UTC")
    assert SipDate.encode(dt) == "Thu, 29 Feb 2024 01:02:03 GMT"
    assert {:ok, _} = SipDate.parse(SipDate.now())
  end

  property "dates survive an encode/parse round trip" do
    check all secs <- integer(0..4_102_444_800) do
      dt = DateTime.from_unix!(secs)
      assert SipDate.parse(SipDate.encode(dt)) == {:ok, dt}
    end
  end
end
