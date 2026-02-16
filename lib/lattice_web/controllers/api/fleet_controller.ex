defmodule LatticeWeb.Api.FleetController do
  @moduledoc """
  API controller for fleet-wide operations.

  Provides endpoints for querying fleet status and triggering fleet-wide
  reconciliation audits.
  """

  use LatticeWeb, :controller

  alias Lattice.Sprites.FleetManager

  @doc """
  GET /api/fleet — fleet summary with sprite counts by state and overall health.
  """
  def index(conn, _params) do
    summary = FleetManager.fleet_summary()

    conn
    |> put_status(200)
    |> json(%{
      data: %{
        total: summary.total,
        by_state: serialize_by_state(summary.by_state)
      },
      timestamp: DateTime.utc_now()
    })
  end

  @doc """
  POST /api/fleet/audit — trigger a fleet-wide reconciliation audit.
  """
  def audit(conn, _params) do
    :ok = FleetManager.run_audit()

    conn
    |> put_status(200)
    |> json(%{
      data: %{status: "audit_triggered"},
      timestamp: DateTime.utc_now()
    })
  end

  # Convert atom keys to strings for consistent JSON output
  defp serialize_by_state(by_state) do
    Map.new(by_state, fn {state, count} -> {Atom.to_string(state), count} end)
  end
end
