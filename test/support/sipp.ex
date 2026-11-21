defmodule Caracola.Test.Sipp do
  @moduledoc false
  # Runs SIPp (https://sipp.sourceforge.net) for the interoperability and
  # load tests (test/interop, tagged :sipp and :load)

  @scenarios Path.expand("../interop/scenarios", __DIR__)

  def available?, do: System.find_executable("sipp") != nil

  def scenario(name), do: Path.join(@scenarios, name)

  @doc """
  Runs sipp with `args`, returning the exit status, the cumulative
  successful and failed calls, and the output.
  """
  def run(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60)
    args = args ++ ["-nostdin", "-timeout", "#{timeout}s", "-timeout_error"]
    {out, status} = System.cmd("sipp", args, stderr_to_stdout: true, cd: System.tmp_dir!())

    %{
      status: status,
      ok: counter(out, "Successful call"),
      failed: counter(out, "Failed call"),
      out: out
    }
  end

  @doc "Starts sipp in the background (as UAS), returning a Task with its result."
  def async(args, opts \\ []), do: Task.async(fn -> run(args, opts) end)

  # Cumulative value of a counter of the last statistics screen
  defp counter(out, name) do
    case Regex.scan(~r/#{name}\s+\|\s+\d+\s+\|\s+(\d+)/, out) do
      [] -> nil
      matches -> matches |> List.last() |> List.last() |> String.to_integer()
    end
  end

  @doc "A free UDP and TCP port on 127.0.0.1."
  def free_port do
    {:ok, udp} = :gen_udp.open(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(udp)

    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}) do
      {:ok, tcp} ->
        :gen_tcp.close(tcp)
        :gen_udp.close(udp)
        port

      {:error, _} ->
        :gen_udp.close(udp)
        free_port()
    end
  end

  @doc "Lines of the output with the call flow and the statistics, for logs."
  def summary(%{out: out}) do
    out
    |> String.split("\n")
    |> Enum.filter(
      &(&1 =~ ~r/<--|-->|Successful call|Failed call|Call Rate|Response Time|Retrans/)
    )
    |> Enum.take(-25)
    |> Enum.join("\n")
  end
end
