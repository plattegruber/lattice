defmodule Lattice.Capabilities.GitHub.ReviewTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Review
  alias Lattice.Capabilities.GitHub.ReviewComment

  describe "Review.from_json/1" do
    test "parses approved review" do
      json = %{
        "id" => 123,
        "user" => %{"login" => "alice"},
        "state" => "APPROVED",
        "body" => "LGTM",
        "submitted_at" => "2026-01-15T10:00:00Z"
      }

      review = Review.from_json(json)

      assert review.id == 123
      assert review.author == "alice"
      assert review.state == :approved
      assert review.body == "LGTM"
      assert review.submitted_at == "2026-01-15T10:00:00Z"
    end

    test "parses changes_requested review" do
      json = %{
        "id" => 456,
        "user" => %{"login" => "bob"},
        "state" => "CHANGES_REQUESTED",
        "body" => "Need fixes",
        "submitted_at" => "2026-01-15T11:00:00Z"
      }

      review = Review.from_json(json)
      assert review.state == :changes_requested
    end

    test "defaults unknown state to :commented" do
      json = %{"id" => 1, "user" => %{"login" => "x"}, "state" => "PENDING"}
      assert Review.from_json(json).state == :commented
    end

    test "handles missing body" do
      json = %{"id" => 1, "user" => %{"login" => "x"}, "state" => "COMMENTED"}
      assert Review.from_json(json).body == ""
    end
  end

  describe "ReviewComment.from_json/1" do
    test "parses inline comment" do
      json = %{
        "id" => 789,
        "path" => "lib/foo.ex",
        "line" => 42,
        "body" => "Please fix this",
        "user" => %{"login" => "alice"},
        "created_at" => "2026-01-15T12:00:00Z",
        "in_reply_to_id" => nil,
        "commit_id" => "abc123"
      }

      comment = ReviewComment.from_json(json)

      assert comment.id == 789
      assert comment.path == "lib/foo.ex"
      assert comment.line == 42
      assert comment.body == "Please fix this"
      assert comment.author == "alice"
      assert comment.commit_id == "abc123"
      assert comment.in_reply_to_id == nil
    end

    test "falls back to original_line when line is nil" do
      json = %{
        "id" => 1,
        "path" => "lib/foo.ex",
        "line" => nil,
        "original_line" => 10,
        "body" => "test",
        "user" => %{"login" => "bob"}
      }

      assert ReviewComment.from_json(json).line == 10
    end

    test "parses reply comment" do
      json = %{
        "id" => 2,
        "path" => "lib/foo.ex",
        "line" => 5,
        "body" => "Done!",
        "user" => %{"login" => "carol"},
        "in_reply_to_id" => 1
      }

      comment = ReviewComment.from_json(json)
      assert comment.in_reply_to_id == 1
    end
  end
end
