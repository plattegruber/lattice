defmodule LatticeWeb.Plugs.RequireRole do
  @moduledoc """
  Plug that enforces role-based access control on API routes.

  Must be used after `LatticeWeb.Plugs.Auth`, which sets
  `conn.assigns.current_operator`. Returns 403 Forbidden if the
  operator does not have the required role level.

  ## Usage

      pipeline :operator_api do
        plug LatticeWeb.Plugs.Auth
        plug LatticeWeb.Plugs.RequireRole, role: :operator
      end
  """

  import Plug.Conn

  alias Lattice.Auth.Operator

  @behaviour Plug

  @impl true
  def init(opts) do
    role = Keyword.fetch!(opts, :role)

    unless role in Operator.valid_roles() do
      raise ArgumentError, "invalid role: #{inspect(role)}"
    end

    role
  end

  @impl true
  def call(%{assigns: %{current_operator: operator}} = conn, required_role) do
    if Operator.has_role?(operator, required_role) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "forbidden", required_role: required_role}))
      |> halt()
    end
  end

  def call(conn, _required_role) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
