defmodule Lattice.Capabilities.GitHub.FeedbackParserTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.FeedbackParser
  alias Lattice.Capabilities.GitHub.Review
  alias Lattice.Capabilities.GitHub.ReviewComment

  describe "parse_reviews/2" do
    test "returns :approved signal for approved review" do
      reviews = [%Review{id: 1, author: "alice", state: :approved}]

      assert [{:approved, "alice"}] = FeedbackParser.parse_reviews(reviews)
    end

    test "returns :changes_requested signal with inline comments" do
      reviews = [%Review{id: 1, author: "bob", state: :changes_requested}]

      comments = [
        %ReviewComment{
          id: 10,
          body: "Please fix this",
          author: "bob",
          path: "lib/foo.ex",
          line: 5
        }
      ]

      assert [{:changes_requested, "bob", matched_comments}] =
               FeedbackParser.parse_reviews(reviews, comments)

      assert length(matched_comments) == 1
      assert hd(matched_comments).body == "Please fix this"
    end

    test "returns :commented signal for general feedback" do
      reviews = [%Review{id: 1, author: "carol", state: :commented}]

      assert [{:commented, "carol", []}] = FeedbackParser.parse_reviews(reviews)
    end

    test "handles mixed review verdicts" do
      reviews = [
        %Review{id: 1, author: "alice", state: :approved},
        %Review{id: 2, author: "bob", state: :changes_requested}
      ]

      comments = [
        %ReviewComment{id: 10, body: "Fix the bug", author: "bob", path: "lib/bug.ex", line: 10}
      ]

      signals = FeedbackParser.parse_reviews(reviews, comments)

      assert {:approved, "alice"} in signals

      assert Enum.any?(signals, fn
               {:changes_requested, "bob", [comment]} -> comment.body == "Fix the bug"
               _ -> false
             end)
    end

    test "comments without matching reviewer get empty list" do
      reviews = [%Review{id: 1, author: "alice", state: :changes_requested}]

      comments = [
        %ReviewComment{id: 10, body: "My comment", author: "bob", path: "lib/foo.ex", line: 1}
      ]

      assert [{:changes_requested, "alice", []}] =
               FeedbackParser.parse_reviews(reviews, comments)
    end
  end

  describe "group_by_file/1" do
    test "groups comments by file path" do
      comments = [
        %ReviewComment{id: 1, body: "Fix A", author: "alice", path: "lib/a.ex", line: 1},
        %ReviewComment{id: 2, body: "Fix B", author: "alice", path: "lib/b.ex", line: 5},
        %ReviewComment{id: 3, body: "Fix A2", author: "bob", path: "lib/a.ex", line: 10}
      ]

      grouped = FeedbackParser.group_by_file(comments)

      assert length(grouped["lib/a.ex"]) == 2
      assert length(grouped["lib/b.ex"]) == 1
    end

    test "skips comments without a path" do
      comments = [
        %ReviewComment{id: 1, body: "General", author: "alice", path: nil, line: nil},
        %ReviewComment{id: 2, body: "Inline", author: "alice", path: "lib/foo.ex", line: 5}
      ]

      grouped = FeedbackParser.group_by_file(comments)

      assert map_size(grouped) == 1
      assert Map.has_key?(grouped, "lib/foo.ex")
    end

    test "returns empty map for empty list" do
      assert %{} == FeedbackParser.group_by_file([])
    end
  end

  describe "extract_action_items/1" do
    test "matches comments with action keywords" do
      comments = [
        %ReviewComment{
          id: 1,
          body: "Please rename this variable",
          author: "alice",
          path: "lib/a.ex",
          line: 1
        },
        %ReviewComment{id: 2, body: "Looks good!", author: "alice", path: "lib/b.ex", line: 1},
        %ReviewComment{
          id: 3,
          body: "You should add a test",
          author: "bob",
          path: "lib/c.ex",
          line: 1
        }
      ]

      items = FeedbackParser.extract_action_items(comments)

      assert length(items) == 2
      bodies = Enum.map(items, & &1.body)
      assert "Please rename this variable" in bodies
      assert "You should add a test" in bodies
    end

    test "is case insensitive" do
      comments = [
        %ReviewComment{id: 1, body: "PLEASE FIX THIS", author: "alice", path: "lib/a.ex", line: 1}
      ]

      assert length(FeedbackParser.extract_action_items(comments)) == 1
    end

    test "returns empty list when no action keywords found" do
      comments = [
        %ReviewComment{
          id: 1,
          body: "Interesting approach",
          author: "alice",
          path: "lib/a.ex",
          line: 1
        },
        %ReviewComment{id: 2, body: "Nice!", author: "bob", path: "lib/b.ex", line: 1}
      ]

      assert [] == FeedbackParser.extract_action_items(comments)
    end

    test "returns empty list for empty input" do
      assert [] == FeedbackParser.extract_action_items([])
    end
  end
end
