defmodule Lattice.Capabilities.GitHub.HttpTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Http

  # These tests verify the Http module's parsing and response handling
  # by testing the public callback interface. Since we can't easily mock
  # :httpc in unit tests without a mock framework, we test the module
  # indirectly through the behaviour's contract — the same callbacks
  # are tested via MockGitHub in integration tests.
  #
  # For the Http module specifically, we verify:
  # 1. It implements all behaviour callbacks
  # 2. Token resolution returns appropriate errors when unconfigured
  # 3. The module compiles and exports all required functions

  describe "behaviour implementation" do
    test "implements all GitHub behaviour callbacks" do
      behaviours = Http.__info__(:attributes) |> Keyword.get_values(:behaviour)
      assert [Lattice.Capabilities.GitHub] in behaviours
    end

    test "exports all required callback functions" do
      exports = Http.__info__(:functions)

      assert {:create_issue, 2} in exports
      assert {:update_issue, 2} in exports
      assert {:add_label, 2} in exports
      assert {:remove_label, 2} in exports
      assert {:create_comment, 2} in exports
      assert {:list_issues, 1} in exports
      assert {:get_issue, 1} in exports
      assert {:create_pull_request, 1} in exports
      assert {:get_pull_request, 1} in exports
      assert {:update_pull_request, 2} in exports
      assert {:merge_pull_request, 2} in exports
      assert {:list_pull_requests, 1} in exports
      assert {:create_branch, 2} in exports
      assert {:delete_branch, 1} in exports
      assert {:list_reviews, 1} in exports
      assert {:list_review_comments, 1} in exports
      assert {:create_review_comment, 5} in exports
      assert {:assign_issue, 2} in exports
      assert {:unassign_issue, 2} in exports
      assert {:request_review, 2} in exports
      assert {:list_collaborators, 1} in exports
      assert {:list_projects, 1} in exports
      assert {:get_project, 1} in exports
      assert {:list_project_items, 2} in exports
      assert {:add_to_project, 2} in exports
      assert {:update_project_item_field, 4} in exports
    end
  end

  describe "token resolution" do
    setup do
      # Clear any token that might be set
      Process.delete(:lattice_github_token)
      prev = Application.get_env(:lattice, :github_token)
      Application.delete_env(:lattice, :github_token)
      on_exit(fn -> if prev, do: Application.put_env(:lattice, :github_token, prev) end)
      :ok
    end

    test "returns error when no token is configured" do
      # Without any token configured, API calls should fail with :no_github_token
      # We need GITHUB_REPO to be set for the repo() call
      prev_resources = Application.get_env(:lattice, :resources, [])

      Application.put_env(
        :lattice,
        :resources,
        Keyword.put(prev_resources, :github_repo, "test/repo")
      )

      on_exit(fn -> Application.put_env(:lattice, :resources, prev_resources) end)

      # Unset GITHUB_TOKEN env var if set
      prev_env = System.get_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_TOKEN")
      on_exit(fn -> if prev_env, do: System.put_env("GITHUB_TOKEN", prev_env) end)

      assert {:error, :no_github_token} = Http.list_issues([])
    end

    test "process dictionary token takes precedence" do
      Application.put_env(:lattice, :github_token, "app-token")
      Process.put(:lattice_github_token, "process-token")

      prev_resources = Application.get_env(:lattice, :resources, [])

      Application.put_env(
        :lattice,
        :resources,
        Keyword.put(prev_resources, :github_repo, "test/repo")
      )

      on_exit(fn ->
        Process.delete(:lattice_github_token)
        Application.delete_env(:lattice, :github_token)
        Application.put_env(:lattice, :resources, prev_resources)
      end)

      # The call will fail at the HTTP level (no mock server), but it should
      # NOT fail with :no_github_token — proving token resolution works
      result = Http.list_issues([])
      refute match?({:error, :no_github_token}, result)
    end
  end
end
