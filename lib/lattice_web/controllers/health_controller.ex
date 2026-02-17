defmodule LatticeWeb.HealthController do
  @moduledoc """
  Unauthenticated health check endpoint.

  Returns a JSON response with the current status, timestamp, and instance
  identity. Used by load balancers and monitoring systems to verify the
  application is running.
  """
  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Instance

  tags(["Health"])

  operation(:index,
    summary: "Health check",
    description: "Returns service health status and instance identity. Unauthenticated.",
    responses: [
      ok: {"Health check response", "application/json", LatticeWeb.Schemas.HealthResponse}
    ]
  )

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      timestamp: DateTime.utc_now(),
      instance: Instance.identity()
    })
  end
end
