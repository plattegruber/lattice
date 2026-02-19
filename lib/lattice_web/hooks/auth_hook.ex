defmodule LatticeWeb.Hooks.AuthHook do
  @moduledoc """
  LiveView on_mount hook for authenticating operators.

  Reads the session token from the LiveView session (set during the
  initial HTTP request), verifies it via the configured auth provider,
  and assigns the resulting Operator to the socket.

  If authentication fails, redirects to the root path.

  ## Usage

  In a LiveView module:

      on_mount {LatticeWeb.Hooks.AuthHook, :default}

  Or in the router for all LiveViews in a scope:

      live_session :authenticated, on_mount: [{LatticeWeb.Hooks.AuthHook, :default}] do
        live "/fleet", FleetLive
      end

  ## Role-Based Hooks

  For role-specific access control, use the role atoms:

      on_mount {LatticeWeb.Hooks.AuthHook, :operator}
      on_mount {LatticeWeb.Hooks.AuthHook, :admin}
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Lattice.Auth
  alias Lattice.Auth.Operator

  @doc false
  def on_mount(:default, _params, session, socket) do
    authenticate(session, socket)
  end

  def on_mount(:viewer, _params, session, socket) do
    with {:cont, socket} <- authenticate(session, socket) do
      require_role(socket, :viewer)
    end
  end

  def on_mount(:operator, _params, session, socket) do
    with {:cont, socket} <- authenticate(session, socket) do
      require_role(socket, :operator)
    end
  end

  def on_mount(:admin, _params, session, socket) do
    with {:cont, socket} <- authenticate(session, socket) do
      require_role(socket, :admin)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp authenticate(session, socket) do
    token = Map.get(session, "auth_token", "stub")

    case Auth.verify_token(token) do
      {:ok, operator} ->
        {:cont, assign(socket, :current_operator, operator)}

      {:error, _reason} ->
        {:halt, redirect(socket, to: "/login")}
    end
  end

  defp require_role(socket, required_role) do
    operator = socket.assigns.current_operator

    if Operator.has_role?(operator, required_role) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end
end
