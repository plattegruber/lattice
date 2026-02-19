defmodule LatticeWeb.AuthController do
  @moduledoc """
  Handles login, callback, and logout flows via Clerk.

  The login page renders Clerk's sign-in component via JavaScript. On
  successful sign-in, Clerk JS posts the session token to `/auth/callback`,
  which verifies it and creates a Phoenix session. Logout clears the session.
  """
  use LatticeWeb, :controller

  alias Lattice.Auth

  @doc """
  Render the login page with Clerk's sign-in component.
  """
  def login(conn, _params) do
    if get_session(conn, "auth_token") do
      redirect(conn, to: ~p"/sprites")
    else
      conn
      |> put_layout(false)
      |> render(:login, clerk_publishable_key: clerk_publishable_key())
    end
  end

  @doc """
  Receive the Clerk session token from the JS frontend, verify it,
  and create a Phoenix session.
  """
  def callback(conn, %{"token" => token}) when is_binary(token) do
    case Auth.verify_token(token) do
      {:ok, operator} ->
        conn
        |> put_session("auth_token", token)
        |> put_session("operator_id", operator.id)
        |> put_session("operator_name", operator.name)
        |> put_session("operator_role", to_string(operator.role))
        |> json(%{ok: true, redirect: ~p"/sprites"})

      {:error, reason} ->
        conn
        |> put_status(401)
        |> json(%{error: "Authentication failed", reason: inspect(reason)})
    end
  end

  def callback(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "Missing token parameter"})
  end

  @doc """
  Clear the session and redirect to the login page.
  """
  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  defp clerk_publishable_key do
    System.get_env("CLERK_PUBLISHABLE_KEY") || ""
  end
end
