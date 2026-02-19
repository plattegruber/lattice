defmodule Lattice.Capabilities.GitHubAssignmentTest do
  use ExUnit.Case, async: true

  import Mox

  @moduletag :unit

  alias Lattice.Capabilities.GitHub

  setup :verify_on_exit!

  describe "assign_issue/2" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:assign_issue, fn number, usernames ->
        assert number == 42
        assert usernames == ["alice", "bob"]
        {:ok, %{number: 42, assignees: ["alice", "bob"]}}
      end)

      assert {:ok, issue} = GitHub.assign_issue(42, ["alice", "bob"])
      assert issue.number == 42
    end
  end

  describe "unassign_issue/2" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:unassign_issue, fn number, usernames ->
        assert number == 42
        assert usernames == ["bob"]
        {:ok, %{number: 42, assignees: ["alice"]}}
      end)

      assert {:ok, issue} = GitHub.unassign_issue(42, ["bob"])
      assert issue.assignees == ["alice"]
    end
  end

  describe "request_review/2" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:request_review, fn pr_number, usernames ->
        assert pr_number == 10
        assert usernames == ["reviewer1"]
        :ok
      end)

      assert :ok = GitHub.request_review(10, ["reviewer1"])
    end
  end

  describe "list_collaborators/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_collaborators, fn opts ->
        assert opts == []
        {:ok, [%{login: "alice"}, %{login: "bob"}]}
      end)

      assert {:ok, collaborators} = GitHub.list_collaborators()
      assert length(collaborators) == 2
    end
  end
end
