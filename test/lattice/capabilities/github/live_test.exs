defmodule Lattice.Capabilities.GitHub.LiveTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Live

  describe "parse_issue_from_json/1" do
    test "parses a full issue response" do
      json = %{
        "number" => 42,
        "title" => "Deploy to staging",
        "body" => "Please deploy the new version",
        "state" => "open",
        "labels" => [%{"name" => "proposed"}, %{"name" => "enhancement"}],
        "comments" => [
          %{"id" => 1, "body" => "Looks good to me"},
          %{"id" => 2, "body" => "Approved"}
        ]
      }

      result = Live.parse_issue_from_json(json)

      assert result.number == 42
      assert result.title == "Deploy to staging"
      assert result.body == "Please deploy the new version"
      assert result.state == "open"
      assert result.labels == ["proposed", "enhancement"]
      assert length(result.comments) == 2
      assert hd(result.comments).body == "Looks good to me"
    end

    test "handles missing optional fields" do
      json = %{
        "number" => 1,
        "title" => "Minimal issue"
      }

      result = Live.parse_issue_from_json(json)

      assert result.number == 1
      assert result.title == "Minimal issue"
      assert result.body == ""
      assert result.state == "open"
      assert result.labels == []
      assert result.comments == []
    end

    test "handles labels as plain strings" do
      json = %{
        "number" => 5,
        "title" => "Test",
        "labels" => ["bug", "urgent"]
      }

      result = Live.parse_issue_from_json(json)
      assert result.labels == ["bug", "urgent"]
    end

    test "handles labels as objects with name field" do
      json = %{
        "number" => 5,
        "title" => "Test",
        "labels" => [%{"name" => "bug"}, %{"name" => "urgent"}]
      }

      result = Live.parse_issue_from_json(json)
      assert result.labels == ["bug", "urgent"]
    end

    test "handles comments with databaseId instead of id" do
      json = %{
        "number" => 5,
        "title" => "Test",
        "comments" => [%{"databaseId" => 123, "body" => "Hello"}]
      }

      result = Live.parse_issue_from_json(json)
      assert [comment] = result.comments
      assert comment.id == 123
      assert comment.body == "Hello"
    end
  end
end
