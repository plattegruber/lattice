defmodule Lattice.Capabilities.GitHub.StubTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Stub

  describe "create_issue/2" do
    test "creates an issue with the given title" do
      assert {:ok, issue} = Stub.create_issue("Test issue", %{body: "A test body"})
      assert issue.title == "Test issue"
      assert issue.body == "A test body"
      assert issue.state == "open"
      assert is_integer(issue.number)
    end

    test "defaults to empty body when not provided" do
      assert {:ok, issue} = Stub.create_issue("No body", %{})
      assert issue.body == ""
    end

    test "accepts labels in attrs" do
      assert {:ok, issue} = Stub.create_issue("Labeled", %{labels: ["bug", "urgent"]})
      assert issue.labels == ["bug", "urgent"]
    end
  end

  describe "update_issue/2" do
    test "updates a known issue" do
      assert {:ok, issue} = Stub.update_issue(1, %{title: "Updated title"})
      assert issue.title == "Updated title"
      assert issue.number == 1
    end

    test "returns error for an unknown issue" do
      assert {:error, :not_found} = Stub.update_issue(999, %{title: "Nope"})
    end
  end

  describe "add_label/2" do
    test "adds a label to a known issue" do
      assert {:ok, labels} = Stub.add_label(1, "bug")
      assert "bug" in labels
      assert "enhancement" in labels
    end

    test "does not duplicate existing labels" do
      assert {:ok, labels} = Stub.add_label(1, "enhancement")
      assert Enum.count(labels, &(&1 == "enhancement")) == 1
    end

    test "returns error for an unknown issue" do
      assert {:error, :not_found} = Stub.add_label(999, "bug")
    end
  end

  describe "remove_label/2" do
    test "removes a label from a known issue" do
      assert {:ok, labels} = Stub.remove_label(2, "incident")
      refute "incident" in labels
      assert "needs-review" in labels
    end

    test "returns error for an unknown issue" do
      assert {:error, :not_found} = Stub.remove_label(999, "bug")
    end
  end

  describe "create_comment/2" do
    test "creates a comment on a known issue" do
      assert {:ok, comment} = Stub.create_comment(1, "A test comment")
      assert comment.body == "A test comment"
      assert comment.issue_number == 1
      assert is_integer(comment.id)
    end

    test "returns error for an unknown issue" do
      assert {:error, :not_found} = Stub.create_comment(999, "Nope")
    end
  end

  describe "list_issues/1" do
    test "returns all issues when no filters are given" do
      assert {:ok, [_, _ | _]} = Stub.list_issues([])
    end

    test "filters issues by label" do
      assert {:ok, [_ | _] = issues} = Stub.list_issues(labels: ["incident"])
      assert Enum.all?(issues, fn issue -> "incident" in issue.labels end)
    end

    test "returns empty list when no issues match filter" do
      assert {:ok, issues} = Stub.list_issues(labels: ["nonexistent-label"])
      assert issues == []
    end
  end
end
