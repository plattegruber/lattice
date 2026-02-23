defmodule Lattice.Context.RendererTest do
  use ExUnit.Case
  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Review
  alias Lattice.Capabilities.GitHub.ReviewComment
  alias Lattice.Context.Renderer

  describe "render_issue/2" do
    test "renders issue with title, metadata, and body" do
      issue = %{
        number: 42,
        title: "Fix the bug",
        body: "Something is broken.",
        state: "open",
        labels: ["bug", "urgent"],
        author: "alice"
      }

      md = Renderer.render_issue(issue)

      assert md =~ "# Issue #42: Fix the bug"
      assert md =~ "| Author | alice |"
      assert md =~ "| State | open |"
      assert md =~ "`bug`, `urgent`"
      assert md =~ "Something is broken."
    end

    test "renders issue with no body" do
      issue = %{number: 1, title: "Empty", body: "", state: "open", labels: []}
      md = Renderer.render_issue(issue)
      assert md =~ "_No description provided._"
    end

    test "renders issue with comments" do
      issue = %{number: 1, title: "Test", body: "body", state: "open", labels: []}

      comments = [
        %{user: "bob", body: "Looks good", created_at: "2026-01-01T00:00:00Z"},
        %{user: "alice", body: "Thanks!"}
      ]

      md = Renderer.render_issue(issue, comments)
      assert md =~ "## Comments"
      assert md =~ "@bob"
      assert md =~ "Looks good"
      assert md =~ "@alice"
    end

    test "handles string-keyed maps" do
      issue = %{
        "number" => 5,
        "title" => "String keys",
        "body" => "body text",
        "state" => "closed",
        "labels" => [%{"name" => "feature"}]
      }

      md = Renderer.render_issue(issue)
      assert md =~ "# Issue #5: String keys"
      assert md =~ "`feature`"
    end
  end

  describe "render_pull_request/2" do
    test "renders PR with metadata and branch info" do
      pr = %{
        number: 99,
        title: "Add feature",
        body: "This adds a thing.",
        state: "open",
        labels: ["enhancement"],
        author: "charlie",
        head: "feature-branch",
        base: "main"
      }

      md = Renderer.render_pull_request(pr)

      assert md =~ "# PR #99: Add feature"
      assert md =~ "| Head | `feature-branch` |"
      assert md =~ "| Base | `main` |"
      assert md =~ "This adds a thing."
    end

    test "includes diff stats when provided" do
      pr = %{number: 1, title: "T", body: "", state: "open", labels: [], head: "h", base: "b"}

      files = [
        %{filename: "lib/foo.ex", status: "modified", additions: 10, deletions: 3},
        %{filename: "lib/bar.ex", status: "added", additions: 25, deletions: 0}
      ]

      md = Renderer.render_pull_request(pr, diff_stats: files)
      assert md =~ "## Changed Files"
      assert md =~ "`lib/foo.ex`"
      assert md =~ "+10"
    end

    test "includes reviews when provided" do
      pr = %{number: 1, title: "T", body: "", state: "open", labels: [], head: "h", base: "b"}

      reviews = [
        %Review{id: 1, author: "reviewer", state: :approved, body: "LGTM"}
      ]

      md = Renderer.render_pull_request(pr, reviews: reviews)
      assert md =~ "## Reviews"
      assert md =~ "@reviewer"
      assert md =~ "APPROVED"
    end
  end

  describe "render_diff_stats/1" do
    test "renders a table of file changes" do
      files = [
        %{filename: "lib/foo.ex", status: "modified", additions: 10, deletions: 2},
        %{filename: "test/foo_test.exs", status: "added", additions: 30, deletions: 0}
      ]

      md = Renderer.render_diff_stats(files)

      assert md =~ "| File | Status | Additions | Deletions |"
      assert md =~ "| `lib/foo.ex` | modified | +10 | -2 |"
      assert md =~ "| `test/foo_test.exs` | added | +30 | -0 |"
      assert md =~ "**Total:** 2 files, +40, -2"
    end

    test "handles empty file list" do
      md = Renderer.render_diff_stats([])
      assert md =~ "**Total:** 0 files, +0, -0"
    end
  end

  describe "render_thread/1" do
    test "renders chronological comments" do
      comments = [
        %{user: "alice", body: "First comment", created_at: "2026-01-01T00:00:00Z"},
        %{user: "bob", body: "Second comment"}
      ]

      md = Renderer.render_thread(comments)

      assert md =~ "### Comment 1 — @alice (2026-01-01T00:00:00Z)"
      assert md =~ "First comment"
      assert md =~ "### Comment 2 — @bob"
      assert md =~ "Second comment"
      assert md =~ "---"
    end

    test "returns placeholder for empty thread" do
      assert Renderer.render_thread([]) == "_No comments._"
    end

    test "handles string-keyed comment maps" do
      comments = [%{"user" => "eve", "body" => "Hello", "created_at" => "2026-01-01"}]
      md = Renderer.render_thread(comments)
      assert md =~ "@eve"
      assert md =~ "Hello"
    end
  end

  describe "render_reviews/2" do
    test "renders review verdicts" do
      reviews = [
        %Review{id: 1, author: "reviewer1", state: :approved, body: "Ship it"},
        %Review{
          id: 2,
          author: "reviewer2",
          state: :changes_requested,
          body: "Needs work"
        }
      ]

      md = Renderer.render_reviews(reviews)

      assert md =~ "@reviewer1 — APPROVED"
      assert md =~ "Ship it"
      assert md =~ "@reviewer2 — CHANGES REQUESTED"
      assert md =~ "Needs work"
    end

    test "includes inline review comments grouped by file" do
      reviews = [%Review{id: 1, author: "rev", state: :commented, body: ""}]

      review_comments = [
        %ReviewComment{id: 1, author: "rev", body: "Fix this", path: "lib/foo.ex", line: 10},
        %ReviewComment{id: 2, author: "rev", body: "And this", path: "lib/foo.ex", line: 20},
        %ReviewComment{id: 3, author: "rev", body: "Check bar", path: "lib/bar.ex", line: 5}
      ]

      md = Renderer.render_reviews(reviews, review_comments)

      assert md =~ "### Inline Comments"
      assert md =~ "`lib/bar.ex`"
      assert md =~ "`lib/foo.ex`"
      assert md =~ "L10"
      assert md =~ "Fix this"
    end

    test "returns placeholder for no reviews" do
      assert Renderer.render_reviews([], []) == "_No reviews._"
    end
  end
end
