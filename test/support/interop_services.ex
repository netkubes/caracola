# Services of the interoperability and load tests (test/interop)

defmodule Caracola.Interop.UAS do
  @moduledoc false
  # Answers INVITEs with the offered SDP, and registers users (with
  # digest authentication if `auth: true`)
  use Malla.Service,
    plugins: [Caracola.Registrar],
    sip: [listen: "sip:127.0.0.1:0"],
    registrar: [min_time: 1]

  defcb sip_invite(req, _call) do
    case Caracola.SDP.from_message(req) do
      nil -> {:reply, :ok}
      sdp -> {:reply, {:answer, %{sdp | address: {"IN", "IP4", "127.0.0.1"}}}}
    end
  end

  defcb sip_get_user_pass(_user, _realm, _req, _call), do: "1234"

  defcb sip_authorize(auth_list, req, call) do
    cond do
      call.service.get_config()[:auth] != true ->
        :ok

      req.class != {:req, :register} ->
        :ok

      List.keyfind(auth_list, {:digest, "example.com"}, 0) == {{:digest, "example.com"}, true} ->
        :ok

      true ->
        {:authenticate, "example.com"}
    end
  end
end

defmodule Caracola.Interop.Proxy do
  @moduledoc false
  # Proxies the requests to the `target`, statefully or not (`stateless:
  # true`), recording the route
  use Malla.Service, plugins: [Caracola], sip: [listen: "sip:127.0.0.1:0"]

  defcb sip_route(_scheme, _user, _domain, req, call) do
    config = call.service.get_config()
    mode = if config[:stateless], do: :proxy_stateless, else: :proxy
    if req.to_tag, do: {mode, :ruri, []}, else: {mode, config[:target], [:record_route]}
  end
end

defmodule Caracola.Interop.UAC do
  @moduledoc false
  use Malla.Service, plugins: [Caracola], sip: [listen: "sip:127.0.0.1:0"]
end

defmodule Caracola.Interop.FsUA do
  @moduledoc false
  # User agents of the FreeSWITCH tests (FsUA1 and FsUA2). They answer
  # INVITEs with the offered SDP, or with 486 (`busy: true` in the config),
  # or do not answer (`ring: true`), accept unsolicited NOTIFYs, and send
  # the requests they receive to the `test_pid` of their config.

  defmacro __using__(_) do
    quote do
      use Malla.Service,
        plugins: [Caracola.SessionTimers, Caracola.Rel100, Caracola.Replaces],
        sip: [listen: "sip:127.0.0.1:0"]

      alias Caracola.{Dialog, SDP}

      defcb sip_invite(req, call) do
        config = call.service.get_config()
        notify(call, {:invite, req.from.user})

        notify(
          call,
          {:invite_identity, req.from, Caracola.Message.header(req, "p-asserted-identity"),
           Caracola.Message.header(req, "privacy")}
        )

        cond do
          config[:busy] -> {:reply, :busy}
          config[:ring] -> {:reply, :ringing}
          true -> {:reply, answer(req)}
        end
      end

      defcb sip_reinvite(req, call) do
        notify(call, {:reinvite, SDP.from_message(req)})
        {:reply, answer(req)}
      end

      defcb sip_ack(req, call) do
        notify(call, {:ack, Dialog.handle(req)})
        :ok
      end

      defcb sip_cancel(_invite, _cancel, call) do
        notify(call, :cancel)
        :ok
      end

      defcb sip_bye(_req, call) do
        notify(call, :bye)
        {:reply, :ok}
      end

      defcb sip_info(req, call) do
        notify(call, {:info, req.body})
        {:reply, :ok}
      end

      defcb sip_notify(req, call) do
        notify(call, {:notify, req.body})
        {:reply, :ok}
      end

      # As the message waiting ones of Asterisk
      defcb sip_unsolicited_notify(req, call) do
        notify(call, {:unsolicited_notify, req.body})
        {:reply, :ok}
      end

      defp answer(req) do
        case SDP.from_message(req) do
          nil -> :ok
          sdp -> {:answer, %{sdp | address: {"IN", "IP4", "127.0.0.1"}}}
        end
      end

      defp notify(call, msg) do
        case call.service.get_config()[:test_pid] do
          pid when is_pid(pid) -> send(pid, {call.service, msg})
          _ -> :ok
        end
      end
    end
  end
end

defmodule Caracola.Interop.FsUA1 do
  @moduledoc false
  use Caracola.Interop.FsUA
end

defmodule Caracola.Interop.FsUA2 do
  @moduledoc false
  use Caracola.Interop.FsUA
end

defmodule Caracola.Interop.BsProxy do
  @moduledoc false
  # Registrar, presence compositor and stateful proxy for the "malla.test"
  # domain of the baresip tests, as the tutorial server: requests need
  # digest authentication (password "secret"), unless they come from a
  # registered contact or an authorized origin of their dialog. It supports
  # SIP outbound. With `presence_server: true` it is also the presence
  # server of the domain; otherwise presence SUBSCRIBEs go to the phones.
  use Malla.Service,
    plugins: [Caracola.Registrar, Caracola.Outbound, Caracola.Presence],
    sip: [listen: "sip:127.0.0.1:0"]

  alias Caracola.{Registrar, Transport}

  defcb sip_get_user_pass(_user, "malla.test", _req, _call), do: "secret"
  defcb sip_get_user_pass(_user, _realm, _req, _call), do: false

  defcb sip_authorize(auth_list, req, _call) do
    if :dialog in auth_list or :register in auth_list,
      do: :ok,
      else: digest(List.keyfind(auth_list, {:digest, "malla.test"}, 0), req)
  end

  defp digest({_, true}, _req), do: :ok
  defp digest({_, _}, _req), do: :forbidden
  defp digest(nil, %{class: {:req, :register}}), do: {:authenticate, "malla.test"}
  defp digest(nil, _req), do: {:proxy_authenticate, "malla.test"}

  defcb sip_route(_scheme, nil, "malla.test", _req, _call), do: :process

  # Publications are stored here, for any user
  defcb sip_route(_scheme, _user, "malla.test", %{class: {:req, :publish}}, _call),
    do: :process

  defcb sip_route(scheme, user, "malla.test", req, call) do
    if presence_subscribe?(req, call) do
      :process
    else
      case Registrar.qfind(call.service, scheme, user, "malla.test") do
        [] -> {:reply, :temporarily_unavailable}
        uri_set -> {:proxy, uri_set, [:record_route]}
      end
    end
  end

  defcb sip_route(_scheme, _user, _domain, req, call) do
    if Transport.local?(call.service, req.ruri, call.config),
      do: :process,
      else: :proxy
  end

  defp presence_subscribe?(%{class: {:req, :subscribe}, event: {event, _}}, call),
    do:
      call.service.get_config()[:presence_server] == true and String.downcase(event) == "presence"

  defp presence_subscribe?(_req, _call), do: false
end

defmodule Caracola.Interop.B2B do
  @moduledoc false
  # Registrar and B2BUA for the "malla.test" domain: phones register (with
  # digest authentication, password "secret"), and their INVITEs are
  # bridged to the registered contact of the called user. Bridge events go
  # to the `test_pid`. With `target: uri`, INVITEs are bridged there
  # instead, with the options in `bridge_opts`.
  use Malla.Service,
    plugins: [Caracola.Registrar, Caracola.B2BUA],
    sip: [listen: "sip:127.0.0.1:0"]

  alias Caracola.{B2BUA, Registrar}

  defcb sip_get_user_pass(_user, "malla.test", _req, _call), do: "secret"
  defcb sip_get_user_pass(_user, _realm, _req, _call), do: false

  defcb sip_authorize(auth_list, %{class: {:req, :register}}, _call) do
    case List.keyfind(auth_list, {:digest, "malla.test"}, 0) do
      {_, true} -> :ok
      {_, _} -> :forbidden
      nil -> {:authenticate, "malla.test"}
    end
  end

  defcb sip_authorize(_auth_list, _req, _call), do: :ok

  defcb sip_route(_scheme, _user, _domain, _req, _call), do: :process

  defcb sip_invite(req, call) do
    case call.service.get_config()[:target] do
      nil ->
        case Registrar.find(call.service, :sip, req.ruri.user, "malla.test") do
          [] -> {:reply, :temporarily_unavailable}
          [contact | _] -> B2BUA.bridge(req, contact)
        end

      target ->
        B2BUA.bridge(req, target, call.service.get_config()[:bridge_opts] || [])
    end
  end

  defcb sip_b2bua_update(event, bridge) do
    if pid = bridge.service.get_config()[:test_pid], do: send(pid, {:b2bua, event, bridge})
    :ok
  end
end
