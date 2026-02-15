defmodule Lattice.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LatticeWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lattice, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lattice.PubSub},
      LatticeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Lattice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LatticeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
