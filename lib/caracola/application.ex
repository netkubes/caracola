defmodule Caracola.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Caracola.DNS.Cache,
      Caracola.Call.Auth.Nonces,
      Caracola.Registrar.Store,
      Caracola.EventCompositor.Store,
      Caracola.Notifier.Store,
      Caracola.Notifier.Worker,
      Caracola.RateLimit.Store,
      Caracola.StirShaken.Certs,
      {Registry, keys: :duplicate, name: Caracola.Push.Registry},
      {Registry, keys: :unique, name: Caracola.B2BUA.Registry},
      {DynamicSupervisor, name: Caracola.B2BUA.Supervisor, strategy: :one_for_one},
      Caracola.OverloadControl | Caracola.Transport.children()
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Caracola.Supervisor)
  end
end
