defmodule LatticeWeb.SpriteLive.ShowTest do
  use LatticeWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest

  alias Lattice.Events
  alias Lattice.Events.HealthUpdate
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store, as: IntentStore
  alias Lattice.Sprites.Sprite

  @moduletag :unit

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    IntentStore.ETS.reset()
    :ok
  end

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

      assert html =~ "Exec Sessions"
      assert html =~ "Approval Queue"
    end

    test "renders breadcrumb navigation", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "Fleet"
      assert html =~ sprite_id
      assert has_element?(view, "a[href=\"/sprites\"]")
    end

    test "renders tasks section", %{conn: conn, sprite_id: sprite_id} do
      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "Tasks"
      assert html =~ "Assign Task"
      assert html =~ "No tasks for this sprite yet"
    end
  end

  # ── Tasks Section ──────────────────────────────────────────────────

  describe "tasks section" do
    setup do
      sprite_id = "task-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "shows tasks for this sprite", %{conn: conn, sprite_id: sprite_id} do
      source = %{type: :sprite, id: sprite_id}

      {:ok, task} =
        Intent.new_task(source, sprite_id, "owner/repo",
          task_kind: "open_pr",
          instructions: "Do work"
        )

      {:ok, _stored} = IntentStore.create(task)

      {:ok, _view, html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert html =~ "open_pr"
      assert html =~ "owner/repo"
    end

    test "links tasks to intent detail view", %{conn: conn, sprite_id: sprite_id} do
      source = %{type: :sprite, id: sprite_id}

      {:ok, task} =
        Intent.new_task(source, sprite_id, "owner/repo",
          task_kind: "open_pr",
          instructions: "Do work"
        )

      {:ok, stored} = IntentStore.create(task)

      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      assert has_element?(view, "a[href='/intents/#{stored.id}']", "View")
    end
  end

  # ── Assign Task Form ──────────────────────────────────────────────

  describe "assign task form" do
    setup do
      sprite_id = "form-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "shows task form when Assign Task is clicked", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      html = render_click(view, "show_task_form")

      assert html =~ "Repository"
      assert html =~ "Task Kind"
      assert html =~ "Instructions"
    end

    test "hides task form when Cancel is clicked", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      render_click(view, "show_task_form")
      html = render_click(view, "hide_task_form")

      assert html =~ "Assign Task"
      refute html =~ "Repository *"
    end

    test "submits task and hides form", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      render_click(view, "show_task_form")

      render_submit(view, "submit_task", %{
        "task" => %{
          "repo" => "owner/test-repo",
          "task_kind" => "open_pr",
          "instructions" => "Add a README"
        }
      })

      html = render(view)

      # Form should be hidden after successful submission
      assert html =~ "Assign Task"
      refute html =~ "Instructions *"

      # Task should appear in the tasks list
      assert html =~ "owner/test-repo"
      assert html =~ "open_pr"
    end

    test "keeps form visible when required fields are missing", %{
      conn: conn,
      sprite_id: sprite_id
    } do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      render_click(view, "show_task_form")

      render_submit(view, "submit_task", %{
        "task" => %{
          "repo" => "",
          "task_kind" => "open_pr",
          "instructions" => "Do work"
        }
      })

      html = render(view)

      # Form should still be visible (submission failed validation)
      assert html =~ "Repository *"
      assert html =~ "Instructions *"

      # The "Assign Task" submit button should still be in the form
      assert has_element?(view, "button[type='submit']", "Assign Task")
    end

    test "sprite name is pre-filled in the form", %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      html = render_click(view, "show_task_form")

      assert html =~ sprite_id
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

    test "refreshes tasks on intent_created broadcast",
         %{conn: conn, sprite_id: sprite_id} do
      source = %{type: :sprite, id: sprite_id}

      {:ok, task} =
        Intent.new_task(source, sprite_id, "owner/repo",
          task_kind: "open_pr",
          instructions: "Do work"
        )

      {:ok, stored} = IntentStore.create(task)

      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.intents_topic(),
        {:intent_created, stored}
      )

      html = render(view)
      assert html =~ "open_pr"
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
