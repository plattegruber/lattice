defmodule Lattice.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/plattegruber/lattice"

  def project do
    [
      app: :lattice,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      name: "Lattice",
      source_url: @source_url,
      homepage_url: @source_url,
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Lattice.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp docs do
    [
      main: "Lattice",
      logo: "priv/static/images/logo.svg",
      source_ref: "main",
      extras: [
        {"PHILOSOPHY.md", title: "Philosophy"},
        {"CLAUDE.md", title: "Project Guide"}
      ],
      groups_for_extras: [
        Guides: ~r/.*/
      ],
      groups_for_modules: [
        Sprites: [
          Lattice.Sprites.Sprite,
          Lattice.Sprites.FleetManager,
          Lattice.Sprites.State
        ],
        Intents: [
          Lattice.Intents.Intent,
          Lattice.Intents.Lifecycle,
          Lattice.Intents.Pipeline,
          Lattice.Intents.Store,
          Lattice.Intents.Store.ETS,
          Lattice.Intents.Observation,
          Lattice.Intents.ExecutionResult,
          Lattice.Intents.IntentGenerator,
          Lattice.Intents.IntentGenerator.Default,
          Lattice.Intents.Executor,
          Lattice.Intents.Executor.Router,
          Lattice.Intents.Executor.Runner,
          Lattice.Intents.Executor.Sprite,
          Lattice.Intents.Executor.ControlPlane,
          Lattice.Intents.Governance,
          Lattice.Intents.Governance.Labels,
          Lattice.Intents.Governance.Listener
        ],
        Capabilities: [
          Lattice.Capabilities,
          Lattice.Capabilities.GitHub,
          Lattice.Capabilities.GitHub.Live,
          Lattice.Capabilities.GitHub.Stub,
          Lattice.Capabilities.GitHub.Labels,
          Lattice.Capabilities.GitHub.WorkProposal,
          Lattice.Capabilities.Fly,
          Lattice.Capabilities.Fly.Live,
          Lattice.Capabilities.Fly.Stub,
          Lattice.Capabilities.Sprites,
          Lattice.Capabilities.Sprites.Live,
          Lattice.Capabilities.SecretStore,
          Lattice.Capabilities.SecretStore.Env,
          Lattice.Capabilities.SecretStore.Stub
        ],
        Safety: [
          Lattice.Safety.Action,
          Lattice.Safety.Classifier,
          Lattice.Safety.Gate,
          Lattice.Safety.Audit,
          Lattice.Safety.AuditEntry
        ],
        Events: [
          Lattice.Events,
          Lattice.Events.StateChange,
          Lattice.Events.ReconciliationResult,
          Lattice.Events.HealthUpdate,
          Lattice.Events.ApprovalNeeded,
          Lattice.Events.TelemetryHandler
        ],
        Auth: [
          Lattice.Auth,
          Lattice.Auth.Clerk,
          Lattice.Auth.Operator,
          Lattice.Auth.Stub
        ],
        "Web: LiveViews": [
          LatticeWeb.FleetLive,
          LatticeWeb.SpriteLive.Show,
          LatticeWeb.ApprovalsLive,
          LatticeWeb.IncidentsLive,
          LatticeWeb.IntentsLive,
          LatticeWeb.IntentLive.Show
        ],
        "Web: Controllers": [
          LatticeWeb.PageController,
          LatticeWeb.HealthController,
          LatticeWeb.Api.FleetController,
          LatticeWeb.Api.SpriteController,
          LatticeWeb.Api.IntentController
        ],
        "Web: Plugs & Hooks": [
          LatticeWeb.Plugs.Auth,
          LatticeWeb.Plugs.RequireRole,
          LatticeWeb.Hooks.AuthHook
        ],
        "Web: Infrastructure": [
          LatticeWeb,
          LatticeWeb.Endpoint,
          LatticeWeb.Router,
          LatticeWeb.Telemetry,
          LatticeWeb.Layouts,
          LatticeWeb.CoreComponents,
          LatticeWeb.ErrorHTML,
          LatticeWeb.ErrorJSON,
          LatticeWeb.Gettext
        ],
        Infrastructure: [
          Lattice.Instance,
          Mix.Tasks.Lattice.Audit
        ]
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:open_api_spex, "~> 3.21"},
      {:sprites, git: "https://github.com/superfly/sprites-ex.git"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind lattice", "esbuild lattice"],
      "assets.deploy": [
        "tailwind lattice --minify",
        "esbuild lattice --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
