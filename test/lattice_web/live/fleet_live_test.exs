defmodule LatticeWeb.FleetLiveTest do
  use LatticeWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders fleet overview", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Fleet Overview"
    assert html =~ "Active Sprites"
    assert html =~ "Operational"
  end
end
