defmodule Lattice.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Lattice.Events.TelemetryHandler
  alias Lattice.Instance

  @impl true
  def start(_type, _args) do
    # Attach Lattice domain telemetry handlers before starting the supervision tree.
    # This ensures events emitted during startup are captured.
    TelemetryHandler.attach()

    # Initialize the intent kind registry (ETS table for kind metadata)
    Lattice.Intents.Kind.init()

    # Validate resource bindings and log instance identity at boot.
    # In prod, missing bindings cause a crash (fail fast).
    Instance.validate!()
    Instance.log_boot_info()

    children =
      [
        LatticeWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:lattice, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Lattice.PubSub},
        # PostgreSQL persistence (conditionally started)
        Lattice.Repo,
        # Metadata persistence (key-value store for tags, purpose, labels)
        Lattice.Store.ETS,
        # Intent persistence (ETS always available; Postgres delegates through it)
        Lattice.Intents.Store.ETS,
        # Bridge Run lifecycle events to Intent state transitions
        Lattice.Intents.RunBridge,
        # Webhook deduplication (ETS-backed with TTL sweep)
        Lattice.Webhooks.Dedup,
        # GitHub artifact association registry (ETS-backed)
        Lattice.Capabilities.GitHub.ArtifactRegistry,
        # PR lifecycle tracker (ETS-backed, subscribes to artifact events)
        Lattice.PRs.Tracker,
        # Post summary comments on PRs after fixup runs complete
        Lattice.PRs.PostFixupCommenter
      ] ++
        maybe_pr_monitor() ++
        [
          # Sprite process infrastructure
          {Registry, keys: :unique, name: Lattice.Sprites.Registry},
          {DynamicSupervisor, name: Lattice.Sprites.DynamicSupervisor, strategy: :one_for_one},
          Lattice.Sprites.FleetManager,
          # Exec session registry and supervisor for WebSocket exec connections
          {Registry, keys: :unique, name: Lattice.Sprites.ExecRegistry},
          Lattice.Sprites.ExecSupervisor,
          # Presence tracking for adaptive fleet polling
          LatticeWeb.Presence,
          # Start to serve requests, typically the last entry
          LatticeWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Lattice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LatticeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_pr_monitor do
    config = Application.get_env(:lattice, Lattice.PRs.Monitor, [])

    if Keyword.get(config, :enabled, false) do
      [Lattice.PRs.Monitor]
    else
      []
    end
  end
end
