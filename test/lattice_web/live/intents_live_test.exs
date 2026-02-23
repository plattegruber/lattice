defmodule LatticeWeb.IntentsLiveTest do
  use LatticeWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store

  @moduletag :unit

  setup do
    Store.ETS.reset()
    :ok
  end

  setup %{conn: conn} do
    {:ok, conn: log_in_conn(conn)}
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_intent(attrs \\ []) do
    kind = Keyword.get(attrs, :kind, :action)
    source = Keyword.get(attrs, :source, %{type: :sprite, id: "sprite-001"})
    summary = Keyword.get(attrs, :summary, "Deploy to staging")

    base_opts = [
      summary: summary,
      payload: %{"capability" => "fly", "operation" => "deploy"}
    ]

    opts =
      case kind do
        :action ->
          Keyword.merge(base_opts,
            affected_resources: ["app-staging"],
            expected_side_effects: ["deploy new version"]
          )

        :inquiry ->
          Keyword.merge(base_opts,
            payload: %{
              "what_requested" => "API key",
              "why_needed" => "deploy",
              "scope_of_impact" => "staging",
              "expiration" => "1h"
            }
          )

        :maintenance ->
          base_opts
      end

    {:ok, intent} = apply(Intent, :"new_#{kind}", [source, opts])
    {:ok, stored} = Store.create(intent)
    stored
  end

  # ── Empty State Rendering ──────────────────────────────────────────

  describe "intents dashboard rendering (empty)" do
    test "renders intents page with title", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/intents")

      assert html =~ "Intents"
      assert has_element?(view, "header", "Intents")
    end

    test "shows empty message when no intents exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "No intents found"
    end

    test "displays summary with total of zero", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "Total Intents"
      assert html =~ "0"
    end
  end

  # ── Intent Display ────────────────────────────────────────────────

  describe "intent display" do
    test "shows intent summary and kind", %{conn: conn} do
      create_intent(summary: "Run database migration")

      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "Run database migration"
      assert html =~ "Action"
    end

    test "shows intent state badge", %{conn: conn} do
      create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "proposed"
    end

    test "shows source information", %{conn: conn} do
      create_intent(source: %{type: :sprite, id: "sprite-test"})

      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "sprite:sprite-test"
    end

    test "displays multiple intents", %{conn: conn} do
      create_intent(summary: "First intent")
      create_intent(summary: "Second intent")

      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "First intent"
      assert html =~ "Second intent"
    end

    test "navigates to intent detail via link", %{conn: conn} do
      intent = create_intent(summary: "Clickable intent")

      {:ok, view, _html} = live(conn, ~p"/intents")

      assert has_element?(view, "a[href='/intents/#{intent.id}']", "View")
    end
  end

  # ── Summary Stats ──────────────────────────────────────────────────

  describe "summary stats" do
    test "displays total intent count", %{conn: conn} do
      create_intent()
      create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "Total Intents"
    end
  end

  # ── Filtering ──────────────────────────────────────────────────────

  describe "filtering" do
    test "filters by kind", %{conn: conn} do
      create_intent(kind: :action, summary: "Action intent")
      create_intent(kind: :maintenance, summary: "Maintenance intent")

      {:ok, view, _html} = live(conn, ~p"/intents")

      html = view |> element("select[name=kind]") |> render_change(%{kind: "action"})

      assert html =~ "Action intent"
      refute html =~ "Maintenance intent"
    end

    test "filters by state", %{conn: conn} do
      create_intent(summary: "Proposed intent")

      {:ok, view, _html} = live(conn, ~p"/intents")

      html = view |> element("select[name=state]") |> render_change(%{state: "proposed"})

      assert html =~ "Proposed intent"
    end

    test "resets filter to show all kinds", %{conn: conn} do
      create_intent(kind: :action, summary: "Action intent")
      create_intent(kind: :maintenance, summary: "Maintenance intent")

      {:ok, view, _html} = live(conn, ~p"/intents")

      # Filter to action only
      view |> element("select[name=kind]") |> render_change(%{kind: "action"})

      # Reset to all
      html = view |> element("select[name=kind]") |> render_change(%{kind: "all"})

      assert html =~ "Action intent"
      assert html =~ "Maintenance intent"
    end
  end

  # ── Sorting ────────────────────────────────────────────────────────

  describe "sorting" do
    test "can sort by oldest first", %{conn: conn} do
      create_intent(summary: "First intent")
      create_intent(summary: "Second intent")

      {:ok, view, _html} = live(conn, ~p"/intents")

      html = view |> element("select[name=sort_by]") |> render_change(%{sort_by: "oldest"})

      assert html =~ "First intent"
      assert html =~ "Second intent"
    end
  end

  # ── Real-time Updates ──────────────────────────────────────────────

  describe "real-time PubSub handling" do
    test "handles intent_created broadcast and refreshes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/intents")

      intent = create_intent(summary: "New PubSub intent")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.intents_all_topic(),
        {:intent_created, intent}
      )

      html = render(view)
      assert html =~ "New PubSub intent"
    end

    test "handles intent_transitioned broadcast and refreshes", %{conn: conn} do
      intent = create_intent(summary: "Transitioning intent")

      {:ok, view, _html} = live(conn, ~p"/intents")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.intents_all_topic(),
        {:intent_transitioned, intent}
      )

      html = render(view)
      assert html =~ "Transitioning intent"
    end

    test "handles unknown PubSub messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/intents")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.intents_all_topic(),
        {:unexpected_message, %{}}
      )

      html = render(view)
      assert html =~ "Intents"
    end
  end

  # ── Task Display ─────────────────────────────────────────────────────

  describe "task intent display" do
    test "shows task-specific inline details", %{conn: conn} do
      source = %{type: :sprite, id: "sprite-001"}

      {:ok, intent} =
        Intent.new_task(source, "my-sprite", "owner/repo",
          task_kind: "open_pr_trivial_change",
          instructions: "Add timestamp"
        )

      {:ok, _stored} = Store.create(intent)

      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "my-sprite"
      assert html =~ "owner/repo"
      assert html =~ "open_pr_trivial_change"
    end
  end

  # ── Task Kind Filter ────────────────────────────────────────────────

  describe "task kind filter" do
    test "filters by task kind", %{conn: conn} do
      source = %{type: :sprite, id: "sprite-001"}

      {:ok, task1} =
        Intent.new_task(source, "sprite-001", "owner/repo1",
          task_kind: "open_pr",
          instructions: "Do PR work"
        )

      {:ok, _} = Store.create(task1)

      {:ok, task2} =
        Intent.new_task(source, "sprite-001", "owner/repo2",
          task_kind: "investigate",
          instructions: "Investigate issue"
        )

      {:ok, _} = Store.create(task2)

      {:ok, view, _html} = live(conn, ~p"/intents")

      html =
        view
        |> element("select[name=task_kind]")
        |> render_change(%{task_kind: "open_pr"})

      assert html =~ "owner/repo1"
      refute html =~ "owner/repo2"
    end

    test "shows task kind filter only when task intents exist", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/intents")

      refute html =~ "Task Kind"

      # Add a task intent
      source = %{type: :sprite, id: "sprite-001"}

      {:ok, task} =
        Intent.new_task(source, "sprite-001", "owner/repo",
          task_kind: "open_pr",
          instructions: "Do work"
        )

      {:ok, _} = Store.create(task)

      # Trigger a refresh via PubSub
      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.intents_topic(),
        {:intent_created, task}
      )

      html = render(view)
      assert html =~ "Task Kind"
    end
  end

  # ── Navigation ─────────────────────────────────────────────────────

  describe "navigation" do
    test "intents route is accessible", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/intents")

      assert html =~ "Intents"
    end
  end
end
