defmodule Lattice.Capabilities.GitHub.AssignmentPolicyTest do
  use ExUnit.Case, async: false

  import Mox

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.AssignmentPolicy

  setup :verify_on_exit!

  setup do
    # Store original config and restore after each test
    original = Application.get_env(:lattice, :github_assignments, [])
    on_exit(fn -> Application.put_env(:lattice, :github_assignments, original) end)
    :ok
  end

  describe "reviewer_for_classification/1" do
    test "returns default_reviewer for :safe" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        dangerous_reviewer: "senior1"
      )

      assert AssignmentPolicy.reviewer_for_classification(:safe) == "operator1"
    end

    test "returns default_reviewer for :controlled" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        dangerous_reviewer: "senior1"
      )

      assert AssignmentPolicy.reviewer_for_classification(:controlled) == "operator1"
    end

    test "returns dangerous_reviewer for :dangerous" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        dangerous_reviewer: "senior1"
      )

      assert AssignmentPolicy.reviewer_for_classification(:dangerous) == "senior1"
    end

    test "falls back to default_reviewer for :dangerous when no dangerous_reviewer" do
      Application.put_env(:lattice, :github_assignments, default_reviewer: "operator1")

      assert AssignmentPolicy.reviewer_for_classification(:dangerous) == "operator1"
    end

    test "returns nil when no reviewer configured" do
      Application.put_env(:lattice, :github_assignments, [])

      assert AssignmentPolicy.reviewer_for_classification(:controlled) == nil
    end
  end

  describe "auto_assign_governance/2" do
    test "assigns issue when enabled and reviewer configured" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        assign_governance_issues: true
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:assign_issue, fn 42, ["operator1"] ->
        {:ok, %{number: 42, assignees: ["operator1"]}}
      end)

      assert :ok = AssignmentPolicy.auto_assign_governance(42, :controlled)
    end

    test "uses dangerous_reviewer for dangerous intents" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        dangerous_reviewer: "senior1",
        assign_governance_issues: true
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:assign_issue, fn 42, ["senior1"] ->
        {:ok, %{number: 42, assignees: ["senior1"]}}
      end)

      assert :ok = AssignmentPolicy.auto_assign_governance(42, :dangerous)
    end

    test "no-ops when disabled" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        assign_governance_issues: false
      )

      # No mock expectation — should not call assign_issue
      assert :ok = AssignmentPolicy.auto_assign_governance(42, :controlled)
    end

    test "no-ops when no reviewer configured" do
      Application.put_env(:lattice, :github_assignments, assign_governance_issues: true)

      # No mock expectation — should not call assign_issue
      assert :ok = AssignmentPolicy.auto_assign_governance(42, :controlled)
    end

    test "gracefully handles assignment failure" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        assign_governance_issues: true
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:assign_issue, fn 42, ["operator1"] ->
        {:error, :not_found}
      end)

      # Should not raise — just log and return :ok
      assert :ok = AssignmentPolicy.auto_assign_governance(42, :controlled)
    end
  end

  describe "auto_request_review/1" do
    test "requests review when enabled and reviewer configured" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        request_pr_reviews: true
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:request_review, fn 10, ["operator1"] ->
        :ok
      end)

      assert :ok = AssignmentPolicy.auto_request_review(10)
    end

    test "no-ops when disabled" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        request_pr_reviews: false
      )

      assert :ok = AssignmentPolicy.auto_request_review(10)
    end

    test "gracefully handles request failure" do
      Application.put_env(:lattice, :github_assignments,
        default_reviewer: "operator1",
        request_pr_reviews: true
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:request_review, fn 10, ["operator1"] ->
        {:error, :unauthorized}
      end)

      assert :ok = AssignmentPolicy.auto_request_review(10)
    end
  end

  describe "assign_governance_issues?/0" do
    test "returns false by default" do
      Application.put_env(:lattice, :github_assignments, [])
      refute AssignmentPolicy.assign_governance_issues?()
    end

    test "returns true when configured" do
      Application.put_env(:lattice, :github_assignments, assign_governance_issues: true)
      assert AssignmentPolicy.assign_governance_issues?()
    end
  end

  describe "request_pr_reviews?/0" do
    test "returns false by default" do
      Application.put_env(:lattice, :github_assignments, [])
      refute AssignmentPolicy.request_pr_reviews?()
    end

    test "returns true when configured" do
      Application.put_env(:lattice, :github_assignments, request_pr_reviews: true)
      assert AssignmentPolicy.request_pr_reviews?()
    end
  end
end
