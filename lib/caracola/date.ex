defmodule Caracola.Date do
  @moduledoc """
  `Date` header values (RFC 3261 §20.17), in the RFC 1123 form that SIP
  requires, always in GMT:

      iex> Caracola.Date.encode(~U[2010-11-13 23:29:00Z])
      "Sat, 13 Nov 2010 23:29:00 GMT"

      iex> Caracola.Date.parse("Sat, 13 Nov 2010 23:29:00 GMT")
      {:ok, ~U[2010-11-13 23:29:00Z]}
  """

  import Caracola.Util

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Parses a `Date` value. The day name is optional, as RFC 1123 allows, but
  must match the date if present.
  """
  @spec parse(binary()) :: {:ok, DateTime.t()} | :error
  def parse(bin) when is_binary(bin) do
    with [day, month, year, time, "GMT"] <- fields(trim(bin)),
         {:ok, day} <- to_integer(day),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, year} <- to_integer(year),
         [hour, min, sec] <- String.split(time, ":"),
         {:ok, hour} <- to_integer(hour),
         {:ok, min} <- to_integer(min),
         {:ok, sec} <- to_integer(sec),
         {:ok, date} <- Date.new(year, month + 1, day),
         {:ok, time} <- Time.new(hour, min, sec),
         {:ok, datetime} <- DateTime.new(date, time) do
      {:ok, datetime}
    else
      _ -> :error
    end
  end

  # Removes the optional day name, checking it later against the date
  defp fields(bin) do
    case String.split(bin, " ", trim: true) do
      [<<day::binary-size(3), ",">> | rest] when day in @days -> check_day(day, rest)
      fields -> fields
    end
  end

  defp check_day(day, fields) do
    with [d, m, y | _] <- fields,
         {:ok, d} <- to_integer(d),
         m when is_integer(m) <- Enum.find_index(@months, &(&1 == m)),
         {:ok, y} <- to_integer(y),
         {:ok, date} <- Date.new(y, m + 1, d),
         ^day <- Enum.at(@days, Date.day_of_week(date) - 1) do
      fields
    else
      _ -> :error
    end
  end

  @doc "Encodes a `DateTime` (converted to UTC) as a `Date` value."
  @spec encode(DateTime.t()) :: String.t()
  def encode(%DateTime{} = datetime) do
    dt = DateTime.shift_zone!(datetime, "Etc/UTC")

    [
      Enum.at(@days, Date.day_of_week(dt) - 1),
      ", ",
      pad(dt.day),
      ?\s,
      Enum.at(@months, dt.month - 1),
      ?\s,
      Integer.to_string(dt.year),
      ?\s,
      pad(dt.hour),
      ?:,
      pad(dt.minute),
      ?:,
      pad(dt.second),
      " GMT"
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Returns the current time as a `Date` value."
  @spec now() :: String.t()
  def now, do: encode(DateTime.utc_now())

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
