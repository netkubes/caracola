defmodule Caracola.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/netkubes/caracola"

  def project do
    [
      app: :caracola,
      version: @version,
      elixir: "~> 1.18",
      description: "SIP stack for Elixir, a rewrite of NkSIP built on Malla.",
      package: package(),
      source_url: @source_url,
      homepage_url: "https://hexdocs.pm/caracola",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      name: "Caracola",
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :xmerl, :crypto, :public_key, :ssl, :inets],
      mod: {Caracola.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "examples", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "examples"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:malla, "~> 0.1.0"},
      {:nimble_options, "~> 1.1"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:telemetry, "~> 1.3"},
      {:thousand_island, "~> 1.3"}
    ]
  end

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/caracola",
        "Changelog" => "https://hexdocs.pm/caracola/changelog.html"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE NOTICE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        "ROADMAP.md": [title: "Roadmap"],
        "guides/01-introduction.md": [title: "Introduction"],
        "guides/02-getting-started.md": [title: "Getting started"],
        "guides/03-tutorial.md": [title: "Tutorial", filename: "tutorial"],
        "guides/15-small-pbx.md": [title: "Tutorial: a small PBX", filename: "small-pbx"],
        "guides/04-sending-requests.md": [title: "Sending requests"],
        "guides/05-receiving-requests.md": [title: "Receiving requests"],
        "guides/06-dialogs-and-subscriptions.md": [title: "Dialogs and subscriptions"],
        "guides/07-proxy.md": [title: "Proxies"],
        "guides/08-authentication.md": [title: "Authentication"],
        "guides/09-transports.md": [title: "Transports"],
        "guides/10-plugins.md": [title: "Plugins"],
        "guides/11-observability.md": [title: "Observability"],
        "guides/12-writing-plugins.md": [title: "Writing plugins"],
        "guides/13-migrating-from-nksip.md": [title: "Migrating from NkSIP"],
        "guides/14-interoperability-and-performance.md": [title: "Interop and performance"]
      ],
      groups_for_extras: [
        Introduction: ~r{guides/0[12]-},
        Tutorials: ~r{guides/(03|15)-},
        Guides: ~r{guides/(0[4-9]|1[01])-},
        Advanced: ~r{guides/1[234]-}
      ],
      groups_for_modules: [
        Core: [Caracola, Caracola.Config, Caracola.UAC, Caracola.Reply, Caracola.Call],
        "Dialogs and events": [Caracola.Dialog, Caracola.Dialog.Invite, Caracola.Subscription],
        Messages: [
          Caracola.Message,
          Caracola.URI,
          Caracola.Via,
          Caracola.Tokens,
          Caracola.Headers,
          Caracola.SDP,
          Caracola.SDP.Media,
          Caracola.SDP.WebRTC,
          Caracola.Parser,
          Caracola.ParseError,
          Caracola.Serializer,
          Caracola.Digest,
          Caracola.Date
        ],
        Transport: [
          Caracola.Transport,
          Caracola.Transport.Port,
          Caracola.Transport.Handler,
          Caracola.DNS,
          Caracola.DNS.Resolver
        ],
        "Plugins: registration and NAT": [
          Caracola.Registrar,
          Caracola.Registrar.Contact,
          Caracola.Registrar.Cluster,
          Caracola.Outbound,
          Caracola.UACAutoOutbound,
          Caracola.UACAutoRegister,
          Caracola.Gruu,
          Caracola.Push
        ],
        "Plugins: call control": [
          Caracola.Rel100,
          Caracola.SessionTimers,
          Caracola.Refer,
          Caracola.Replaces,
          Caracola.Join,
          Caracola.B2BUA,
          Caracola.InfoPackages,
          Caracola.Siprec
        ],
        "Plugins: events and presence": [
          Caracola.EventCompositor,
          Caracola.EventCompositor.Publication,
          Caracola.Notifier,
          Caracola.Presence,
          Caracola.DialogInfo,
          Caracola.MessageWaiting,
          Caracola.Conference,
          Caracola.WatcherInfo
        ],
        "Plugins: security and load": [
          Caracola.AssertedIdentity,
          Caracola.StirShaken,
          Caracola.StirShaken.Passport,
          Caracola.RateLimit,
          Caracola.OverloadControl
        ],
        "Plugins: routing": [Caracola.Dispatcher, Caracola.History],
        Observability: [Caracola.Telemetry, Caracola.HEP],
        Tutorial: [
          Caracola.Tutorial,
          Caracola.Tutorial.Server,
          Caracola.Tutorial.Client,
          Caracola.Tutorial.Client1,
          Caracola.Tutorial.Client2,
          Caracola.Tutorial.Office,
          Caracola.Tutorial.Office.PBX,
          Caracola.Tutorial.Office.Phone,
          Caracola.Tutorial.Office.Alice,
          Caracola.Tutorial.Office.Bob,
          Caracola.Tutorial.Office.Voicemail
        ]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:ex_unit],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
