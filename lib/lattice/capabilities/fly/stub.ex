defmodule Lattice.Capabilities.Fly.Stub do
  @moduledoc """
  Stub implementation of the Fly capability.

  Returns canned responses for development and testing. The Fly capability is
  stub-only for now — real implementation comes in Step 4.
  """

  @behaviour Lattice.Capabilities.Fly

  @impl true
  def deploy(config) do
    {:ok,
     %{
       machine_id: "mach-stub-#{System.unique_integer([:positive])}",
       app: Map.get(config, :app, "lattice-dev"),
       status: "started",
       region: Map.get(config, :region, "iad")
     }}
  end

  @impl true
  def logs(machine_id, _opts) do
    {:ok,
     [
       "[2026-02-16T10:00:00Z] Machine #{machine_id} started",
       "[2026-02-16T10:00:01Z] Health check passed",
       "[2026-02-16T10:00:02Z] Listening on 0.0.0.0:8080"
     ]}
  end

  @impl true
  def machine_status(machine_id) do
    {:ok,
     %{
       machine_id: machine_id,
       state: "started",
       region: "iad",
       image: "lattice:latest",
       created_at: "2026-02-16T10:00:00Z",
       checks: [
         %{name: "http", status: "passing"}
       ]
     }}
  end
end
