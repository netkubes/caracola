defmodule Caracola.Test.Helpers do
  @moduledoc false
  # Common functions for the tests using the test services

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Caracola.Test.{Client, Server}

  # Starts the server and the client, returning the server port
  def start(server_sip \\ [], client_sip \\ []) do
    start_service(Server, sip: server_sip)
    start_service(Client, sip: client_sip)
    port(Server)
  end

  # Starts a test service, returning its port
  def start_service(service, config \\ []) do
    start_supervised!({service, [test_pid: self()] ++ config})
    # Plugins start their children asynchronously
    eventually(fn -> Malla.Service.is_ready?(service) end)
    eventually(fn -> length(Caracola.listeners(service)) >= 2 end)
    port(service)
  end

  # A Route header for a service
  def route(service), do: "<sip:127.0.0.1:#{port(service)};lr>"

  def port(service) do
    [%{local_port: port} | _] = Caracola.listeners(service)
    port
  end

  def eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        :ok

      retries == 0 ->
        flunk("condition not met")

      true ->
        Process.sleep(20)
        eventually(fun, retries - 1)
    end
  end

  # UAC callback sending the replies to the test process
  def callback do
    pid = self()
    fn reply -> send(pid, {:callback, reply}) end
  end
end
