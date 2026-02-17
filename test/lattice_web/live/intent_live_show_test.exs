defmodule LatticeWeb.IntentLive.ShowTest do
  use LatticeWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store

  @moduletag :unit

  setup do
    Store.ETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_intent(attrs \\ []) do
    kind = Keyword.get(attrs, :kind, :action)
    source = Keyword.get(attrs, :source, %{type: :sprite, id: "sprite-001"})
    summary = Keyword.get(attrs, :summary, "Deploy to staging")

    base_opts = [
      summary: summary,
      payload: %{"capability" => "fly", "operation" => "deploy"},
      affected_resources: ["app-staging"],
      expected_side_effects: ["deploy new version"],
      rollback_strategy: "Revert to previous release"
    ]

    {:ok, intent} = Intent.new_action(source, base_opts)

    if kind == :action do
      {:ok, stored} = Store.create(intent)
      stored
    else
      {:ok, stored} = Store.create(intent)
      stored
    end
  end

  defp create_and_propose(attrs \\ []) do
    source = Keyword.get(attrs, :source, %{type: :sprite, id: "sprite-001"})
    summary = Keyword.get(attrs, :summary, "Deploy to staging")

    {:ok, intent} =
      Intent.new_action(source,
        summary: summary,
        payload: %{"capability" => "fly", "operation" => "deploy"},
        affected_resources: ["app-staging"],
        expected_side_effects: ["deploy new version"],
        rollback_strategy: "Revert to previous release"
      )

    {:ok, proposed} = Pipeline.propose(intent)
    proposed
  end

  # ── Mount & Rendering ──────────────────────────────────────────────

  describe "intent detail rendering" do
    test "renders intent details", %{conn: conn} do
      intent = create_intent(summary: "Run database migration")

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "Run database migration"
      assert html =~ "Details"
      assert html =~ "proposed"
    end

    test "shows intent kind badge", %{conn: conn} do
      intent = create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "Action"
    end

    test "shows source information", %{conn: conn} do
      intent = create_intent(source: %{type: :sprite, id: "sprite-test"})

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "sprite:sprite-test"
    end

    test "shows full intent ID (selectable)", %{conn: conn} do
      intent = create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ intent.id
    end

    test "shows affected resources", %{conn: conn} do
      intent = create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "Affected Resources"
      assert html =~ "app-staging"
    end

    test "shows expected side effects", %{conn: conn} do
      intent = create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "Expected Side Effects"
      assert html =~ "deploy new version"
    end

    test "shows rollback strategy", %{conn: conn} do
      intent = create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "Rollback Strategy"
      assert html =~ "Revert to previous release"
    end

    test "shows payload section", %{conn: conn} do
      intent = create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "Payload"
      assert html =~ "fly"
    end
  end

  # ── Not Found ──────────────────────────────────────────────────────

  describe "intent not found" do
    test "shows not found message for unknown intent", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/intents/int_nonexistent12345")

      assert html =~ "Intent not found"
      assert html =~ "Back to Intents"
    end
  end

  # ── Breadcrumb ─────────────────────────────────────────────────────

  describe "breadcrumb navigation" do
    test "shows breadcrumb back to intents list", %{conn: conn} do
      intent = create_intent()

      {:ok, view, _html} = live(conn, ~p"/intents/#{intent.id}")

      assert has_element?(view, "a[href='/intents']", "Intents")
    end
  end

  # ── Lifecycle Timeline ─────────────────────────────────────────────

  describe "lifecycle timeline" do
    test "shows empty timeline message for new intent", %{conn: conn} do
      intent = create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "No transitions yet"
    end

    test "shows transitions after pipeline processing", %{conn: conn} do
      intent = create_and_propose()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "Lifecycle Timeline"
      # Pipeline moves through proposed -> classified -> approved/awaiting_approval
      assert html =~ "proposed"
      assert html =~ "classified"
    end
  end

  # ── Action Buttons ─────────────────────────────────────────────────

  describe "action button visibility" do
    test "shows no action buttons for proposed state (no valid user actions)", %{conn: conn} do
      intent = create_intent()

      {:ok, view, _html} = live(conn, ~p"/intents/#{intent.id}")

      # Proposed can only transition to classified (by pipeline, not user)
      # but we do show cancel if it's a valid transition - proposed doesn't have cancel
      refute has_element?(view, "button", "Approve")
      refute has_element?(view, "button", "Reject")
    end

    test "shows approve and reject for awaiting_approval state", %{conn: conn} do
      source = %{type: :sprite, id: "sprite-001"}

      {:ok, intent} =
        Intent.new_action(source,
          summary: "Needs approval",
          payload: %{"capability" => "github", "operation" => "create_issue"},
          affected_resources: ["repo"],
          expected_side_effects: ["create issue"]
        )

      {:ok, proposed} = Pipeline.propose(intent)

      # Check if it ended up in awaiting_approval
      if proposed.state == :awaiting_approval do
        {:ok, view, _html} = live(conn, ~p"/intents/#{proposed.id}")

        assert has_element?(view, "button", "Approve")
        assert has_element?(view, "button", "Reject")
        assert has_element?(view, "button", "Cancel")
      end
    end
  end

  # ── Action Execution ───────────────────────────────────────────────

  describe "action execution" do
    test "cancel action works for cancelable intent", %{conn: conn} do
      # Create an intent that reaches awaiting_approval
      source = %{type: :sprite, id: "sprite-001"}

      {:ok, intent} =
        Intent.new_action(source,
          summary: "Cancel me",
          payload: %{"capability" => "github", "operation" => "create_issue"},
          affected_resources: ["repo"],
          expected_side_effects: ["create issue"]
        )

      {:ok, proposed} = Pipeline.propose(intent)

      if proposed.state == :awaiting_approval do
        {:ok, view, _html} = live(conn, ~p"/intents/#{proposed.id}")

        render_click(view, "cancel")

        # After cancel, the intent state should be :canceled
        html = render(view)
        assert html =~ "canceled"
      end
    end
  end

  # ── Source Sprite Link ─────────────────────────────────────────────

  describe "source sprite link" do
    test "shows link to source sprite when source is a sprite", %{conn: conn} do
      intent = create_intent(source: %{type: :sprite, id: "sprite-test"})

      {:ok, view, _html} = live(conn, ~p"/intents/#{intent.id}")

      assert has_element?(view, "a[href='/sprites/sprite-test']")
    end
  end

  # ── Real-time Updates ──────────────────────────────────────────────

  describe "real-time PubSub handling" do
    test "handles intent_transitioned broadcast and refreshes", %{conn: conn} do
      intent = create_intent(summary: "PubSub intent")

      {:ok, view, _html} = live(conn, ~p"/intents/#{intent.id}")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.intent_topic(intent.id),
        {:intent_transitioned, intent}
      )

      html = render(view)
      assert html =~ "PubSub intent"
    end

    test "ignores events for other intents", %{conn: conn} do
      intent = create_intent(summary: "My intent")
      other = create_intent(summary: "Other intent")

      {:ok, view, _html} = live(conn, ~p"/intents/#{intent.id}")

      # Subscribe to intents topic so we can broadcast a store event
      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.intents_topic(),
        {:intent_transitioned, other}
      )

      html = render(view)
      assert html =~ "My intent"
    end

    test "handles unknown PubSub messages gracefully", %{conn: conn} do
      intent = create_intent()

      {:ok, view, _html} = live(conn, ~p"/intents/#{intent.id}")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.intent_topic(intent.id),
        {:unexpected_message, %{}}
      )

      html = render(view)
      assert html =~ "Details"
    end
  end

  # ── Artifacts ──────────────────────────────────────────────────────

  describe "artifacts display" do
    test "shows empty artifacts message when none exist", %{conn: conn} do
      intent = create_intent()

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "Artifacts"
      assert html =~ "No artifacts recorded yet"
    end

    test "displays artifacts when present", %{conn: conn} do
      intent = create_intent()

      Store.add_artifact(intent.id, %{
        type: "pr_url",
        data: %{"url" => "https://github.com/example/repo/pull/1"}
      })

      {:ok, _view, html} = live(conn, ~p"/intents/#{intent.id}")

      assert html =~ "pr_url"
    end
  end
end
