defmodule Caracola.SessionTimersTest do
  # Services have global names
  use ExUnit.Case, async: false

  alias Caracola.{Dialog, Message, SDP, SessionTimers, UAC}
  alias Caracola.Test.{Client, Location, Server, TimerProxy, TimerUA1, TimerUA2}

  import Caracola.Test.Helpers

  # Adapted from NkSIP's t20_timers. TimerUA1 has a Min-SE of 1, TimerUA2 of
  # 2 and TimerProxy of 3.

  @answer {:add, "x-op", "answer"}
  @increment {:add, "x-op", "increment"}

  defp expires(dialog), do: elem(SessionTimers.session_expires(dialog), 1)
  defp refresh(dialog), do: elem(SessionTimers.session_refresh(dialog), 1)

  defp remote({:dialog, _, call_id, _}, service) do
    [dialog] = Dialog.list(service, call_id)
    dialog
  end

  defp session_expires(%Message{} = msg), do: Message.header(msg, "session-expires")

  test "negotiation, refresh and expiration" do
    port = start_service(TimerUA2)
    start_service(TimerUA1)
    uri = "sip:127.0.0.1:#{port}"

    # Below its own Min-SE
    assert UAC.invite(TimerUA2, uri, session_expires: 1) ==
             {:error, {:invalid_config, :session_expires}}

    # 422 and new request with the Min-SE of the response
    assert {:ok, 200, [{:dialog, dia}, {"session-expires", ["2;refresher=uas"]}]} =
             UAC.invite(TimerUA1, uri, [
               @answer,
               :auto_2xx_ack,
               :get_request,
               body: SDP.new("timer1"),
               session_expires: 1,
               callback: callback(),
               get_meta: ["session-expires"]
             ])

    assert_receive {:callback, {:req, req1}}
    assert {session_expires(req1), Message.header(req1, "min-se")} == {["1"], []}
    assert_receive {:callback, {:req, req2}}
    assert {session_expires(req2), Message.header(req2, "min-se")} == {["2"], ["2"]}
    assert elem(req2.cseq, 0) == elem(req1.cseq, 0) + 1

    # TimerUA2 is the refresher, and gets the notification after 1 sec
    dib = remote(dia, TimerUA2)
    # The ACK is sent at once, without waiting for it to be processed
    eventually(fn -> expires(dib) == 2 end)
    assert {expires(dia), refresh(dia)} == {2, nil}
    assert expires(dib) == 2
    assert is_integer(refresh(dib))
    assert_receive {TimerUA2, {:dialog, {:invite_refresh, %SDP{}}}}, 1_500
    assert refresh(dib) == :expired

    # TimerUA2 refreshes, with a Min-SE of 3: the interval is raised
    assert {:ok, 200, [dialog: ^dib]} = UAC.refresh(dib, [@increment, :auto_2xx_ack, min_se: 3])
    eventually(fn -> expires(dia) == 3 end)
    assert {expires(dia), refresh(dia), expires(dib)} == {3, nil, 3}
    assert is_integer(refresh(dib))

    # An UPDATE without Min-SE: the default (90) is used
    assert {:ok, 200, [{"session-expires", ["90;refresher=uac"]}]} =
             UAC.update(dib, get_meta: ["session-expires"])

    assert {expires(dia), expires(dib)} == {90, 90}

    # A 422 to an UPDATE, the Min-SE is remembered in both dialogs
    assert {:ok, 200, [{"session-expires", ["2;refresher=uas"]}]} =
             UAC.update(dia, session_expires: 1, get_meta: ["session-expires"])

    assert {expires(dia), refresh(dia), expires(dib)} == {2, nil, 2}

    # The current interval and Min-SE are sent automatically, keeping roles
    assert {:ok, 200, [{"session-expires", ["2;refresher=uas"]}]} =
             UAC.update(dia, [:get_request, callback: callback(), get_meta: ["session-expires"]])

    assert_receive {:callback, {:req, req}}
    assert {session_expires(req), Message.header(req, "min-se")} == {["2;refresher=uas"], ["2"]}

    # TimerUA1 becomes the refresher, without Min-SE
    assert {:ok, 200, []} = UAC.update(dia, session_expires: {2, :uac})
    assert {expires(dia), expires(dib), refresh(dib)} == {90, 90, nil}
    assert is_integer(refresh(dia))

    # Without refresh, TimerUA2 sends a BYE before the interval ends
    assert {:ok, 200, []} = UAC.update(dia, session_expires: {2, :uac}, min_se: 2)
    assert {expires(dia), expires(dib)} == {2, 2}
    assert_receive {TimerUA1, {:dialog, {:invite_refresh, _}}}, 1_500
    assert_receive {TimerUA2, {:dialog, :invite_timeout}}, 1_500
    assert_receive {TimerUA1, {:bye, _}}
    assert_receive {TimerUA1, {:dialog, {:invite_status, {:stop, :callee_bye}}}}
    assert_receive {TimerUA2, {:dialog, {:invite_status, {:stop, :callee_bye}}}}
  end

  test "proxy" do
    port2 = start_service(TimerUA2)
    port3 = start_service(Server)
    start_service(TimerUA1)
    start_service(Client)
    start_service(TimerProxy)
    Location.put(TimerProxy, "ua2", "<sip:ua2@127.0.0.1:#{port2}>")
    Location.put(TimerProxy, "ua3", "<sip:ua3@127.0.0.1:#{port3}>")

    on_exit(fn ->
      Location.delete(TimerProxy, "ua2")
      Location.delete(TimerProxy, "ua3")
    end)

    opts = [@answer, :auto_2xx_ack, route: route(TimerProxy), body: SDP.new("timer1")]
    meta = {:get_meta, ["session-expires", "require"]}

    # The proxy rejects 1 with 422 (Min-SE 3)
    assert {:ok, 200, [{:dialog, dia}, {"session-expires", ["3;refresher=uas"]}, _]} =
             UAC.invite(TimerUA1, "sip:ua2@caracola", [meta, session_expires: 1] ++ opts)

    dib = remote(dia, TimerUA2)
    eventually(fn -> expires(dib) == 3 end)
    assert {expires(dia), refresh(dia)} == {3, nil}
    assert is_integer(refresh(dib))
    assert {:ok, 200, []} = UAC.bye(dia)

    # The proxy lowers the interval to its own (1800)
    assert {:ok, 200, [{:dialog, dia}, {"session-expires", ["1800;refresher=uas"]}, _]} =
             UAC.invite(TimerUA1, "sip:ua2@caracola", [meta, session_expires: 1801] ++ opts)

    assert {:ok, 200, []} = UAC.bye(dia)

    # The UAC does not support timers: the UAS accepts the interval added by
    # the proxy, without Require
    assert {:ok, 200,
            [{:dialog, dia}, {"session-expires", ["1800;refresher=uas"]}, {"require", []}]} =
             UAC.invite(Client, "sip:ua2@caracola", [meta] ++ opts)

    eventually(fn -> expires(remote(dia, TimerUA2)) == 1800 end)
    assert {:ok, 200, []} = UAC.bye(dia)

    # The UAS does not support timers: the proxy adds the interval, with the
    # UAC as refresher
    assert {:ok, 200,
            [{:dialog, dia}, {"session-expires", ["1800;refresher=uac"]}, {"require", ["timer"]}]} =
             UAC.invite(TimerUA1, "sip:ua3@caracola", [meta] ++ opts)

    assert expires(dia) == 1800
    assert is_integer(refresh(dia))
    assert expires(remote(dia, Server)) == nil
    assert {:ok, 200, []} = UAC.bye(dia)
  end
end
