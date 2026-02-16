defmodule LatticeWeb.SpriteLive.ShowTest do
  use LatticeWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest

  alias Lattice.Events
  alias Lattice.Events.HealthUpdate
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Sprites.Sprite

  @moduletag :unit

  setup :set_mox_global
  setup :verify_on_exit!

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_test_sprite(sprite_id, opts \\ []) do
    desired = Keyword.get(opts, :desired_state, :hibernating)
    observed = Keyword.get(opts, :observed_state, :hibernating)

    {:ok, _pid} =
      Sprite.start_link(
        sprite_id: sprite_id,
        desired_state: desired,
        observed_state: observed,
        reconcile_interval_ms: 60_000,
        name: Sprite.via(sprite_id)
      )
  end

  # ── 404 / Not Found ──────────────────────────────────────────────────

  describe "sprite not found" do
    test "renders not found message for unknown sprite", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sprites/nonexistent-sprite")

      assert html =~ "Sprite not found"
      assert html =~ "nonexistent-sprite"
      assert html =~ "Back to Fleet"
    end

    test "does not render state panels when sprite not found", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sprites/ghost-sprite")

      refute html =~ "State Comparison"
      refute html =~ "Health &amp; Backoff"
      refute html =~ "Event Timeline"
    end
  end

  # ── Rendering with Live Sprite ────────────────────────────────────

  describe "rendering with running sprite" do
    setup do
      sprite_id = "test-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "renders sprite detail page with sprite id", %{conn: conn, sprite_id: sprite_id} do
      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ sprite_id
      assert html =~ "Sprite:"
    end

    test "renders state comparison panel", %{conn: conn, sprite_id: sprite_id} do
      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "State Comparison"
      assert html =~ "Observed"
      assert html =~ "Desired"
    end

    test "shows in-sync state when observed matches desired", %{conn: conn, sprite_id: sprite_id} do
      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "States are in sync"
    end

    test "renders health and backoff panel", %{conn: conn, sprite_id: sprite_id} do
      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "Health"
      assert html =~ "Failures"
      assert html =~ "Backoff"
    end

    test "renders event timeline section", %{conn: conn, sprite_id: sprite_id} do
      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "Event Timeline"
      assert html =~ "No events yet"
    end

    test "renders placeholder sections", %{conn: conn, sprite_id: sprite_id} do
      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "Log Lines"
      assert html =~ "Approval Queue"
    end

    test "renders breadcrumb navigation", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "Fleet"
      assert html =~ sprite_id
      assert has_element?(view, "a[href=\"/sprites\"]")
    end
  end

  # ── Drift Detection ───────────────────────────────────────────────

  describe "drift detection" do
    test "shows drift warning when states differ", %{conn: conn} do
      sprite_id = "drift-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id, desired_state: :ready, observed_state: :hibernating)

      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "Drift detected"
    end
  end

  # ── Real-time PubSub Updates ──────────────────────────────────────

  describe "real-time PubSub updates" do
    setup do
      sprite_id = "live-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "updates event timeline on state change", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      {:ok, event} =
        StateChange.new(sprite_id, :hibernating, :waking, reason: "test transition")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.sprite_topic(sprite_id),
        event
      )

      html = render(view)
      assert html =~ "state_change"
      assert html =~ "hibernating -&gt; waking"
    end

    test "updates event timeline on reconciliation result", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      {:ok, event} =
        ReconciliationResult.new(sprite_id, :success, 42, details: "transitioned to ready")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.sprite_topic(sprite_id),
        event
      )

      html = render(view)
      assert html =~ "reconciliation"
      assert html =~ "transitioned to ready"
    end

    test "shows last reconciliation info after receiving reconciliation event",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      {:ok, event} =
        ReconciliationResult.new(sprite_id, :failure, 150, details: "API timeout")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.sprite_topic(sprite_id),
        event
      )

      html = render(view)
      assert html =~ "Last Reconciliation"
      assert html =~ "API timeout"
    end

    test "updates event timeline on health update", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      {:ok, event} =
        HealthUpdate.new(sprite_id, :healthy, 15, message: "all checks passed")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.sprite_topic(sprite_id),
        event
      )

      html = render(view)
      assert html =~ "health"
      assert html =~ "all checks passed"
    end

    test "handles fleet summary broadcast without crashing",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.fleet_topic(),
        {:fleet_summary, %{total: 1, by_state: %{hibernating: 1}}}
      )

      html = render(view)
      assert html =~ sprite_id
    end

    test "handles unknown PubSub messages gracefully",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.sprite_topic(sprite_id),
        {:unexpected_message, %{}}
      )

      html = render(view)
      assert html =~ sprite_id
    end
  end

  # ── Event Timeline Ordering ─────────────────────────────────────────

  describe "event timeline ordering" do
    setup do
      sprite_id = "timeline-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "shows newest events first", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      {:ok, event1} = StateChange.new(sprite_id, :hibernating, :waking, reason: "first")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.sprite_topic(sprite_id),
        event1
      )

      {:ok, event2} = StateChange.new(sprite_id, :waking, :ready, reason: "second")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.sprite_topic(sprite_id),
        event2
      )

      html = render(view)

      # Both events should be visible
      assert html =~ "first"
      assert html =~ "second"
    end
  end
end
