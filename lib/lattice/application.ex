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

    # Validate resource bindings and log instance identity at boot.
    # In prod, missing bindings cause a crash (fail fast).
    Instance.validate!()
    Instance.log_boot_info()

    children = [
      LatticeWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lattice, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lattice.PubSub},
      # Metadata persistence (key-value store for tags, purpose, labels)
      Lattice.Store.ETS,
      # Intent persistence
      Lattice.Intents.Store.ETS,
      # Sprite process infrastructure
      {Registry, keys: :unique, name: Lattice.Sprites.Registry},
      {DynamicSupervisor, name: Lattice.Sprites.DynamicSupervisor, strategy: :one_for_one},
      Lattice.Sprites.FleetManager,
      # Exec session supervisor for WebSocket exec connections
      Lattice.Sprites.ExecSupervisor,
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
end
