defmodule LatticeWeb.PageControllerTest do
  use LatticeWeb.ConnCase

  test "GET / redirects to /login when not authenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET / redirects to /sprites when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{"auth_token" => "valid-token"})
      |> get(~p"/")

    assert redirected_to(conn) == "/sprites"
  end
end
