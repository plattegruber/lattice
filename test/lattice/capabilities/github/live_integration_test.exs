defmodule Lattice.Capabilities.GitHub.LiveIntegrationTest do
  @moduledoc """
  Integration tests for the live GitHub capability backed by the `gh` CLI.

  These tests hit the real GitHub API via the `gh` CLI and require:

  1. The `gh` CLI to be installed and authenticated (`gh auth login`)
  2. The `GITHUB_REPO` environment variable set (e.g., `plattegruber/lattice`)

  Run with:

      GITHUB_REPO=owner/repo mix test --only integration test/lattice/capabilities/github/live_integration_test.exs

  WARNING: These tests create real GitHub issues. Use a test repository.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Lattice.Capabilities.GitHub.Live

  setup do
    unless System.get_env("GITHUB_REPO") do
      raise "GITHUB_REPO must be set for integration tests"
    end

    # Temporarily override capabilities config to use Live implementation
    original = Application.get_env(:lattice, :capabilities)

    Application.put_env(
      :lattice,
      :capabilities,
      Keyword.put(original, :github, Lattice.Capabilities.GitHub.Live)
    )

    on_exit(fn ->
      Application.put_env(:lattice, :capabilities, original)
    end)

    :ok
  end

  describe "list_issues/1" do
    test "returns {:ok, list} from the live API" do
      assert {:ok, issues} = Live.list_issues([])
      assert is_list(issues)

      for issue <- issues do
        assert Map.has_key?(issue, :number)
        assert Map.has_key?(issue, :title)
        assert Map.has_key?(issue, :labels)
        assert is_integer(issue.number)
      end
    end

    test "filters by label" do
      assert {:ok, _issues} = Live.list_issues(labels: ["bug"])
    end
  end

  describe "create_issue/2 and get_issue/1" do
    test "creates an issue and retrieves it" do
      title = "Integration test issue #{System.unique_integer([:positive])}"

      assert {:ok, issue} =
               Live.create_issue(title, %{
                 body: "This is an automated integration test issue. Safe to close.",
                 labels: []
               })

      assert issue.title == title
      assert is_integer(issue.number)

      # Retrieve the same issue
      assert {:ok, fetched} = Live.get_issue(issue.number)
      assert fetched.number == issue.number
      assert fetched.title == title
    end
  end

  describe "get_issue/1" do
    test "returns {:error, :not_found} for a nonexistent issue" do
      assert {:error, :not_found} = Live.get_issue(999_999_999)
    end
  end
end
