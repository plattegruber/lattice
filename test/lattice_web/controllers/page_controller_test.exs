defmodule LatticeWeb.PageControllerTest do
  use LatticeWeb.ConnCase

  test "GET / redirects to /sprites", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/sprites"
  end
end
