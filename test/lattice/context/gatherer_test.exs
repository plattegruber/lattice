defmodule Lattice.Context.GathererTest do
  use ExUnit.Case
  @moduletag :unit

  import Mox

  alias Lattice.Capabilities.GitHub.Review
  alias Lattice.Capabilities.GitHub.ReviewComment
  alias Lattice.Context.Bundle
  alias Lattice.Context.Gatherer
  alias Lattice.Context.Trigger

  setup :set_mox_global
  setup :verify_on_exit!

  @issue_trigger %Trigger{
    type: :issue,
    number: 42,
    repo: "owner/repo",
    title: "Fix bug",
    body: "The thing is broken. See #10 for context."
  }

  @pr_trigger %Trigger{
    type: :pull_request,
    number: 99,
    repo: "owner/repo",
    title: "Add feature",
    body: "Implements #42."
  }

  @issue_data %{
    number: 42,
    title: "Fix bug",
    body: "The thing is broken. See #10 for context.",
    state: "open",
    labels: ["bug"],
    comments: []
  }

  @pr_data %{
    number: 99,
    title: "Add feature",
    body: "Implements #42.",
    state: "open",
    labels: [],
    head: "feature",
    base: "main"
  }

  @linked_issue %{
    number: 10,
    title: "Original report",
    body: "Something was wrong.",
    state: "closed",
    labels: [],
    comments: []
  }

  describe "gather/2 with issue trigger" do
    test "gathers issue context with trigger.md, thread.md, and expanded refs" do
      Lattice.Capabilities.MockGitHub
      # get_issue for trigger
      |> expect(:get_issue, fn 42 -> {:ok, @issue_data} end)
      # list_comments for thread
      |> expect(:list_comments, fn 42 ->
        {:ok, [%{user: "bob", body: "I see it too", created_at: "2026-01-01"}]}
      end)
      # get_issue for expansion of #10
      |> expect(:get_issue, fn 10 -> {:ok, @linked_issue} end)

      assert {:ok, %Bundle{} = bundle} = Gatherer.gather(@issue_trigger)

      assert bundle.trigger_type == :issue
      assert bundle.trigger_number == 42

      # Should have trigger.md, thread.md, and linked/issue_10.md
      paths = Enum.map(bundle.files, & &1.path)
      assert "trigger.md" in paths
      assert "thread.md" in paths
      assert "linked/issue_10.md" in paths

      # Linked items should include #10
      assert [%{number: 10, title: "Original report"}] = bundle.linked_items
      assert bundle.expansion_budget.used == 1
    end

    test "reuses pre-fetched thread_context instead of calling list_comments" do
      trigger = %{@issue_trigger | thread_context: [%{user: "pre", body: "pre-fetched"}]}

      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 -> {:ok, @issue_data} end)
      # No list_comments expected — using thread_context

      # #10 expansion
      |> expect(:get_issue, fn 10 -> {:ok, @linked_issue} end)

      assert {:ok, %Bundle{} = bundle} = Gatherer.gather(trigger)

      thread_file = Enum.find(bundle.files, &(&1.path == "thread.md"))
      assert thread_file.content =~ "pre-fetched"
    end

    test "respects expansion budget" do
      trigger = %{@issue_trigger | body: "See #1, #2, #3, #4, #5, #6, #7"}

      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 -> {:ok, @issue_data} end)
      |> expect(:list_comments, fn 42 -> {:ok, []} end)
      # Only 5 expansions (default budget), not 7
      |> expect(:get_issue, 5, fn n ->
        {:ok,
         %{number: n, title: "Issue #{n}", body: "", state: "open", labels: [], comments: []}}
      end)

      assert {:ok, %Bundle{} = bundle} = Gatherer.gather(trigger)
      assert bundle.expansion_budget.used == 5
      assert bundle.expansion_budget.max == 5

      linked_paths =
        bundle.files
        |> Enum.filter(&String.starts_with?(&1.path, "linked/"))
        |> Enum.map(& &1.path)

      assert length(linked_paths) == 5
    end

    test "records warning when expansion fails" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 -> {:ok, @issue_data} end)
      |> expect(:list_comments, fn 42 -> {:ok, []} end)
      |> expect(:get_issue, fn 10 -> {:error, :not_found} end)

      assert {:ok, %Bundle{} = bundle} = Gatherer.gather(@issue_trigger)
      assert length(bundle.warnings) == 1
      assert hd(bundle.warnings) =~ "#10"
    end

    test "propagates GitHub error on get_issue failure" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 -> {:error, :rate_limited} end)

      assert {:error, :rate_limited} = Gatherer.gather(@issue_trigger)
    end
  end

  describe "gather/2 with PR trigger" do
    test "gathers PR context with all files" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_pull_request, fn 99 -> {:ok, @pr_data} end)
      |> expect(:list_comments, fn 99 -> {:ok, []} end)
      |> expect(:list_pr_files, fn 99 ->
        {:ok, [%{filename: "lib/foo.ex", status: "modified", additions: 5, deletions: 2}]}
      end)
      |> expect(:list_reviews, fn 99 ->
        {:ok, [%Review{id: 1, author: "rev", state: :approved, body: "LGTM"}]}
      end)
      |> expect(:list_review_comments, fn 99 ->
        {:ok,
         [
           %ReviewComment{
             id: 1,
             author: "rev",
             body: "Nit",
             path: "lib/foo.ex",
             line: 10
           }
         ]}
      end)
      # expansion of #42
      |> expect(:get_issue, fn 42 ->
        {:ok,
         %{number: 42, title: "Fix bug", body: "desc", state: "open", labels: [], comments: []}}
      end)

      assert {:ok, %Bundle{} = bundle} = Gatherer.gather(@pr_trigger)

      assert bundle.trigger_type == :pull_request
      paths = Enum.map(bundle.files, & &1.path)
      assert "trigger.md" in paths
      assert "thread.md" in paths
      assert "diff_stats.md" in paths
      assert "reviews.md" in paths
      assert "linked/issue_42.md" in paths
    end

    test "gracefully handles PR files fetch failure" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_pull_request, fn 99 -> {:ok, @pr_data} end)
      |> expect(:list_comments, fn 99 -> {:ok, []} end)
      |> expect(:list_pr_files, fn 99 -> {:error, :rate_limited} end)
      |> expect(:list_reviews, fn 99 -> {:ok, []} end)
      |> expect(:list_review_comments, fn 99 -> {:ok, []} end)
      |> expect(:get_issue, fn 42 ->
        {:ok, %{number: 42, title: "Fix bug", body: "", state: "open", labels: [], comments: []}}
      end)

      # Should succeed even though list_pr_files failed (graceful fallback)
      assert {:ok, %Bundle{}} = Gatherer.gather(@pr_trigger)
    end
  end

  describe "extract_issue_refs/1" do
    test "extracts issue references from text" do
      assert Gatherer.extract_issue_refs("See #42 and #10") == [10, 42]
    end

    test "ignores refs in code blocks" do
      text = """
      See #42.

      ```
      # This is #99 in code
      ```

      Also `#50` in inline code.
      """

      assert Gatherer.extract_issue_refs(text) == [42]
    end

    test "deduplicates refs" do
      assert Gatherer.extract_issue_refs("#42 and #42 again") == [42]
    end

    test "returns empty list for no refs" do
      assert Gatherer.extract_issue_refs("No refs here") == []
    end

    test "ignores hash in words" do
      assert Gatherer.extract_issue_refs("color#42 is not a ref") == []
    end
  end
end
