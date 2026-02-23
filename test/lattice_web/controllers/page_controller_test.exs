defmodule LatticeWeb.PageControllerTest do
  use LatticeWeb.ConnCase

  test "GET / redirects to /login when not authenticated" do
    conn = Phoenix.ConnTest.build_conn() |> get(~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET / redirects to /sprites when authenticated", %{conn: conn} do
    conn = conn |> log_in_conn() |> get(~p"/")
    assert redirected_to(conn) == "/sprites"
  end
end
