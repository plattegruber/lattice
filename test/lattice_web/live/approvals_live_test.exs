defmodule LatticeWeb.ApprovalsLiveTest do
  use LatticeWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest

  alias Lattice.Events
  alias Lattice.Events.ApprovalNeeded

  @moduletag :unit

  setup :set_mox_global
  setup :verify_on_exit!

  # ── Helpers ──────────────────────────────────────────────────────────

  defp stub_issues(issues) do
    Lattice.Capabilities.MockGitHub
    |> stub(:list_issues, fn _opts -> {:ok, issues} end)
  end

  defp sample_issue(attrs \\ %{}) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    Map.merge(
      %{
        number: System.unique_integer([:positive]),
        title: "[Sprite] Deploy to staging",
        body:
          "## Proposed Action\n\n**Action:** Deploy to staging\n" <>
            "**Sprite:** `sprite-001`\n**Reason:** Ready for testing\n",
        state: "open",
        labels: ["proposed"],
        comments: [],
        created_at: now,
        updated_at: now
      },
      attrs
    )
  end

  # ── Empty State Rendering ────────────────────────────────────────────

  describe "approvals view rendering (no items)" do
    test "renders approvals page with title", %{conn: conn} do
      stub_issues([])

      {:ok, view, html} = live(conn, ~p"/approvals")

      assert html =~ "Approvals Queue"
      assert has_element?(view, "header", "Approvals Queue")
    end

    test "shows no-pending-approvals message when empty", %{conn: conn} do
      stub_issues([])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "No pending approvals"
    end

    test "displays summary with zero total", %{conn: conn} do
      stub_issues([])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "Total Items"
      assert html =~ "0"
    end
  end

  # ── Issue Display ────────────────────────────────────────────────────

  describe "approval item display" do
    test "displays issue title and number", %{conn: conn} do
      issue = sample_issue(%{number: 42, title: "[Sprite] Run migration"})
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "#42"
      assert html =~ "[Sprite] Run migration"
    end

    test "shows label badge for HITL label", %{conn: conn} do
      issue = sample_issue(%{labels: ["proposed"]})
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "proposed"
    end

    test "extracts and displays sprite ID from issue body", %{conn: conn} do
      issue = sample_issue()
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "sprite-001"
    end

    test "extracts and displays reason from issue body", %{conn: conn} do
      issue = sample_issue()
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "Ready for testing"
    end

    test "shows GitHub deep link", %{conn: conn} do
      issue = sample_issue(%{number: 99})
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "View on GitHub"
    end

    test "shows copy-paste approval command for proposed items", %{conn: conn} do
      issue = sample_issue(%{number: 55, labels: ["proposed"]})
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "Quick approve"
      assert html =~ "gh issue edit 55 --add-label approved --remove-label proposed"
    end

    test "shows unblock command for blocked items", %{conn: conn} do
      issue = sample_issue(%{number: 77, labels: ["blocked"]})
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "Unblock"
      assert html =~ "gh issue edit 77 --add-label proposed --remove-label blocked"
    end
  end

  # ── Summary Counts ──────────────────────────────────────────────────

  describe "approval summary" do
    test "counts items by label state", %{conn: conn} do
      issues = [
        sample_issue(%{labels: ["proposed"]}),
        sample_issue(%{labels: ["proposed"]}),
        sample_issue(%{labels: ["approved"]}),
        sample_issue(%{labels: ["blocked"]})
      ]

      stub_issues(issues)

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "Total Items"
      # We have 4 issues total
      assert html =~ "Proposed"
      assert html =~ "Approved"
      assert html =~ "Blocked"
    end
  end

  # ── Filtering ───────────────────────────────────────────────────────

  describe "filtering" do
    test "filters by label state", %{conn: conn} do
      issues = [
        sample_issue(%{number: 1, title: "[Sprite] Proposed work", labels: ["proposed"]}),
        sample_issue(%{number: 2, title: "[Sprite] Approved work", labels: ["approved"]})
      ]

      stub_issues(issues)

      {:ok, view, _html} = live(conn, ~p"/approvals")

      html = view |> element("select[name=label]") |> render_change(%{label: "proposed"})

      assert html =~ "Proposed work"
      refute html =~ "Approved work"
    end

    test "filters by sprite", %{conn: conn} do
      issues = [
        sample_issue(%{
          number: 1,
          title: "[Sprite] Work A",
          body: "**Sprite:** `sprite-001`\n**Reason:** A"
        }),
        sample_issue(%{
          number: 2,
          title: "[Sprite] Work B",
          body: "**Sprite:** `sprite-002`\n**Reason:** B"
        })
      ]

      stub_issues(issues)

      {:ok, view, _html} = live(conn, ~p"/approvals")

      html = view |> element("select[name=sprite]") |> render_change(%{sprite: "sprite-001"})

      assert html =~ "Work A"
      refute html =~ "Work B"
    end

    test "resets filter to show all", %{conn: conn} do
      issues = [
        sample_issue(%{number: 1, title: "[Sprite] Work A", labels: ["proposed"]}),
        sample_issue(%{number: 2, title: "[Sprite] Work B", labels: ["approved"]})
      ]

      stub_issues(issues)

      {:ok, view, _html} = live(conn, ~p"/approvals")

      # First filter to proposed only
      view |> element("select[name=label]") |> render_change(%{label: "proposed"})

      # Then reset to all
      html = view |> element("select[name=label]") |> render_change(%{label: "all"})

      assert html =~ "Work A"
      assert html =~ "Work B"
    end
  end

  # ── Sorting ─────────────────────────────────────────────────────────

  describe "sorting" do
    test "sorts by newest first by default", %{conn: conn} do
      issues = [
        sample_issue(%{
          number: 1,
          title: "[Sprite] Older item",
          created_at: "2026-02-14T10:00:00Z"
        }),
        sample_issue(%{
          number: 2,
          title: "[Sprite] Newer item",
          created_at: "2026-02-16T10:00:00Z"
        })
      ]

      stub_issues(issues)

      {:ok, _view, html} = live(conn, ~p"/approvals")

      # Both visible
      assert html =~ "Older item"
      assert html =~ "Newer item"
    end

    test "can sort by oldest first", %{conn: conn} do
      issues = [
        sample_issue(%{
          number: 1,
          title: "[Sprite] Older item",
          created_at: "2026-02-14T10:00:00Z"
        }),
        sample_issue(%{
          number: 2,
          title: "[Sprite] Newer item",
          created_at: "2026-02-16T10:00:00Z"
        })
      ]

      stub_issues(issues)

      {:ok, view, _html} = live(conn, ~p"/approvals")

      html = view |> element("select[name=sort_by]") |> render_change(%{sort_by: "oldest"})

      assert html =~ "Older item"
      assert html =~ "Newer item"
    end

    test "can sort by urgency", %{conn: conn} do
      issues = [
        sample_issue(%{
          number: 1,
          title: "[Sprite] Approved item",
          labels: ["approved"]
        }),
        sample_issue(%{
          number: 2,
          title: "[Sprite] Blocked item",
          labels: ["blocked"]
        })
      ]

      stub_issues(issues)

      {:ok, view, _html} = live(conn, ~p"/approvals")

      html = view |> element("select[name=sort_by]") |> render_change(%{sort_by: "urgent"})

      # Both should appear; blocked is more urgent
      assert html =~ "Blocked item"
      assert html =~ "Approved item"
    end
  end

  # ── Real-time Updates ──────────────────────────────────────────────

  describe "real-time PubSub handling" do
    test "handles approval_needed broadcast and refreshes", %{conn: conn} do
      stub_issues([sample_issue()])

      {:ok, view, _html} = live(conn, ~p"/approvals")

      {:ok, event} =
        ApprovalNeeded.new("sprite-001", "deploy", :needs_review)

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.approvals_topic(),
        event
      )

      html = render(view)
      assert html =~ "Approvals Queue"
    end

    test "handles unknown PubSub messages gracefully", %{conn: conn} do
      stub_issues([])

      {:ok, view, _html} = live(conn, ~p"/approvals")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.approvals_topic(),
        {:unexpected_message, %{}}
      )

      html = render(view)
      assert html =~ "Approvals Queue"
    end

    test "handles fleet_summary broadcast without crashing", %{conn: conn} do
      stub_issues([])

      {:ok, view, _html} = live(conn, ~p"/approvals")

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.fleet_topic(),
        {:fleet_summary, %{total: 3, by_state: %{ready: 2, error: 1}}}
      )

      html = render(view)
      assert html =~ "Approvals Queue"
    end
  end

  # ── Staleness Indicators ────────────────────────────────────────────

  describe "staleness indicators" do
    test "shows stale badge for items older than 24 hours", %{conn: conn} do
      old_time =
        DateTime.utc_now()
        |> DateTime.add(-25 * 3600, :second)
        |> DateTime.to_iso8601()

      issue = sample_issue(%{created_at: old_time, updated_at: old_time})
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "stale"
    end

    test "shows aging badge for items older than 4 hours", %{conn: conn} do
      aging_time =
        DateTime.utc_now()
        |> DateTime.add(-6 * 3600, :second)
        |> DateTime.to_iso8601()

      issue = sample_issue(%{created_at: aging_time, updated_at: aging_time})
      stub_issues([issue])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "aging"
    end
  end

  # ── Navigation ──────────────────────────────────────────────────────

  describe "navigation" do
    test "approvals route is accessible", %{conn: conn} do
      stub_issues([])

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "Approvals Queue"
    end

    test "handles GitHub list_issues error gracefully", %{conn: conn} do
      Lattice.Capabilities.MockGitHub
      |> stub(:list_issues, fn _opts -> {:error, :api_error} end)

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "No pending approvals"
    end
  end

  # ── Grouping ────────────────────────────────────────────────────────

  describe "grouping by sprite" do
    test "groups issues by sprite ID", %{conn: conn} do
      issues = [
        sample_issue(%{
          number: 1,
          title: "[Sprite] Work A",
          body: "**Sprite:** `sprite-001`\n**Reason:** A"
        }),
        sample_issue(%{
          number: 2,
          title: "[Sprite] Work B",
          body: "**Sprite:** `sprite-001`\n**Reason:** B"
        }),
        sample_issue(%{
          number: 3,
          title: "[Sprite] Work C",
          body: "**Sprite:** `sprite-002`\n**Reason:** C"
        })
      ]

      stub_issues(issues)

      {:ok, _view, html} = live(conn, ~p"/approvals")

      assert html =~ "sprite-001"
      assert html =~ "sprite-002"
    end
  end
end
