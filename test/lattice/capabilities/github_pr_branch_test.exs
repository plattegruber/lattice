defmodule Lattice.Capabilities.GitHubPrBranchTest do
  use ExUnit.Case, async: true

  import Mox

  @moduletag :unit

  alias Lattice.Capabilities.GitHub

  setup :verify_on_exit!

  # ── Pull Request Callbacks ──────────────────────────────────────────

  describe "create_pull_request/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:create_pull_request, fn attrs ->
        assert attrs.title == "Add feature"
        assert attrs.head == "feat/branch"
        assert attrs.base == "main"

        {:ok,
         %{
           number: 10,
           title: "Add feature",
           body: "",
           state: "OPEN",
           head: "feat/branch",
           base: "main",
           mergeable: "MERGEABLE",
           labels: [],
           url: "https://github.com/owner/repo/pull/10"
         }}
      end)

      assert {:ok, pr} =
               GitHub.create_pull_request(%{
                 title: "Add feature",
                 head: "feat/branch",
                 base: "main"
               })

      assert pr.number == 10
      assert pr.state == "OPEN"
    end
  end

  describe "get_pull_request/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_pull_request, fn number ->
        assert number == 10

        {:ok,
         %{
           number: 10,
           title: "Add feature",
           body: "Description",
           state: "OPEN",
           head: "feat/branch",
           base: "main",
           mergeable: "MERGEABLE",
           labels: [],
           url: "https://github.com/owner/repo/pull/10"
         }}
      end)

      assert {:ok, pr} = GitHub.get_pull_request(10)
      assert pr.number == 10
      assert pr.title == "Add feature"
    end
  end

  describe "update_pull_request/2" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:update_pull_request, fn number, attrs ->
        assert number == 10
        assert attrs.title == "Updated title"

        {:ok,
         %{
           number: 10,
           title: "Updated title",
           body: "",
           state: "OPEN",
           head: "feat/branch",
           base: "main",
           mergeable: "MERGEABLE",
           labels: [],
           url: "https://github.com/owner/repo/pull/10"
         }}
      end)

      assert {:ok, pr} = GitHub.update_pull_request(10, %{title: "Updated title"})
      assert pr.title == "Updated title"
    end
  end

  describe "merge_pull_request/2" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:merge_pull_request, fn number, opts ->
        assert number == 10
        assert opts[:method] == :squash

        {:ok,
         %{
           number: 10,
           title: "Add feature",
           body: "",
           state: "MERGED",
           head: "feat/branch",
           base: "main",
           mergeable: nil,
           labels: [],
           url: "https://github.com/owner/repo/pull/10"
         }}
      end)

      assert {:ok, pr} = GitHub.merge_pull_request(10, method: :squash)
      assert pr.state == "MERGED"
    end

    test "uses default empty opts" do
      Lattice.Capabilities.MockGitHub
      |> expect(:merge_pull_request, fn 10, [] ->
        {:ok, %{number: 10, state: "MERGED"}}
      end)

      assert {:ok, _pr} = GitHub.merge_pull_request(10)
    end
  end

  describe "list_pull_requests/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_pull_requests, fn opts ->
        assert opts[:state] == "open"

        {:ok,
         [
           %{number: 10, title: "PR 1", state: "OPEN"},
           %{number: 11, title: "PR 2", state: "OPEN"}
         ]}
      end)

      assert {:ok, prs} = GitHub.list_pull_requests(state: "open")
      assert length(prs) == 2
    end

    test "uses default empty opts" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_pull_requests, fn [] ->
        {:ok, []}
      end)

      assert {:ok, []} = GitHub.list_pull_requests()
    end
  end

  # ── Branch Callbacks ────────────────────────────────────────────────

  describe "create_branch/2" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:create_branch, fn name, base ->
        assert name == "feat/new-branch"
        assert base == "main"
        :ok
      end)

      assert :ok = GitHub.create_branch("feat/new-branch", "main")
    end

    test "returns error on failure" do
      Lattice.Capabilities.MockGitHub
      |> expect(:create_branch, fn _name, _base ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} = GitHub.create_branch("feat/missing", "nonexistent")
    end
  end

  describe "delete_branch/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_branch, fn name ->
        assert name == "feat/old-branch"
        :ok
      end)

      assert :ok = GitHub.delete_branch("feat/old-branch")
    end

    test "returns error on failure" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_branch, fn _name ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} = GitHub.delete_branch("nonexistent")
    end
  end
end
