defmodule LatticeWeb.FleetLiveTest do
  use LatticeWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Lattice.Events
  alias Lattice.Events.StateChange

  @moduletag :unit

  # The global FleetManager starts with an empty fleet in tests (config/test.exs).
  # Tests that need sprites start them via a dedicated FleetManager+DynamicSupervisor
  # pair, but since the LiveView reads from the global FleetManager, we test
  # the empty-fleet rendering and PubSub handling separately.

  # ── Empty Fleet Rendering ──────────────────────────────────────────

  describe "fleet dashboard rendering (empty fleet)" do
    test "renders fleet dashboard with page title", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/sprites")

      assert html =~ "Fleet Dashboard"
      assert has_element?(view, "header", "Fleet Dashboard")
    end

    test "shows empty fleet message when no sprites exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sprites")

      assert html =~ "No sprites in the fleet"
    end

    test "displays fleet summary with total of zero", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sprites")

      assert html =~ "Total Sprites"
      assert html =~ "0"
    end

    test "renders the sprites table header", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sprites")

      assert html =~ "Sprite ID"
      assert html =~ "State"
      assert html =~ "Health"
      assert html =~ "Last Update"
    end
  end

  # ── Real-time Updates ──────────────────────────────────────────────

  describe "real-time PubSub handling" do
    test "handles fleet_summary broadcast without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sprites")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.fleet_topic(),
        {:fleet_summary, %{total: 5, by_state: %{ready: 3, hibernating: 2}}}
      )

      # The view should process the message and still be alive
      html = render(view)
      assert html =~ "Fleet Dashboard"
      assert html =~ "Total Sprites"
    end

    test "handles state change broadcast without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sprites")

      {:ok, event} =
        StateChange.new("some-sprite", :hibernating, :waking, reason: "test")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.fleet_topic(),
        event
      )

      html = render(view)
      assert html =~ "Fleet Dashboard"
    end

    test "handles unknown PubSub messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sprites")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.fleet_topic(),
        {:unexpected_message, %{}}
      )

      html = render(view)
      assert html =~ "Fleet Dashboard"
    end
  end

  # ── Sprite Detail Navigation ──────────────────────────────────────

  describe "sprite detail navigation" do
    test "sprite detail route renders for unknown sprite", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sprites/test-sprite-001")

      assert html =~ "test-sprite-001"
      assert html =~ "Sprite not found"
      assert html =~ "Back to Fleet"
    end
  end
end
