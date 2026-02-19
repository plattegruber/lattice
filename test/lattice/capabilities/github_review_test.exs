defmodule Lattice.Capabilities.GitHubReviewTest do
  use ExUnit.Case, async: true

  import Mox

  @moduletag :unit

  alias Lattice.Capabilities.GitHub

  setup :verify_on_exit!

  describe "list_reviews/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn pr_number ->
        assert pr_number == 42
        {:ok, [%{id: 1, author: "alice", state: :approved, body: "LGTM"}]}
      end)

      assert {:ok, [review]} = GitHub.list_reviews(42)
      assert review.author == "alice"
    end
  end

  describe "list_review_comments/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_review_comments, fn pr_number ->
        assert pr_number == 42

        {:ok,
         [
           %{id: 10, path: "lib/foo.ex", line: 5, body: "Fix this", author: "bob"}
         ]}
      end)

      assert {:ok, [comment]} = GitHub.list_review_comments(42)
      assert comment.path == "lib/foo.ex"
    end
  end

  describe "create_review_comment/5" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:create_review_comment, fn pr_number, body, path, line, opts ->
        assert pr_number == 42
        assert body == "Please fix"
        assert path == "lib/foo.ex"
        assert line == 10
        assert opts == []

        {:ok, %{id: 20, body: body, path: path, line: line, author: "lattice-bot"}}
      end)

      assert {:ok, comment} = GitHub.create_review_comment(42, "Please fix", "lib/foo.ex", 10)
      assert comment.body == "Please fix"
    end

    test "passes options through" do
      Lattice.Capabilities.MockGitHub
      |> expect(:create_review_comment, fn _pr, _body, _path, _line, opts ->
        assert opts[:commit_id] == "abc123"
        {:ok, %{id: 21}}
      end)

      assert {:ok, _} =
               GitHub.create_review_comment(42, "Note", "lib/bar.ex", 5, commit_id: "abc123")
    end
  end
end
