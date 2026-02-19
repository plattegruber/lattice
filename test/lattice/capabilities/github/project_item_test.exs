defmodule Lattice.Capabilities.GitHub.ProjectItemTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.ProjectItem

  describe "from_graphql/1" do
    test "parses an issue item with field values" do
      data = %{
        "id" => "PVTI_abc",
        "content" => %{
          "__typename" => "Issue",
          "id" => "I_123",
          "title" => "Fix login bug"
        },
        "fieldValues" => %{
          "nodes" => [
            %{
              "name" => "In Progress",
              "field" => %{"name" => "Status"}
            },
            %{
              "text" => "High",
              "field" => %{"name" => "Priority"}
            }
          ]
        }
      }

      item = ProjectItem.from_graphql(data)

      assert %ProjectItem{} = item
      assert item.id == "PVTI_abc"
      assert item.content_id == "I_123"
      assert item.content_type == :issue
      assert item.title == "Fix login bug"
      assert item.field_values["Status"] == "In Progress"
      assert item.field_values["Priority"] == "High"
    end

    test "parses a PR item" do
      data = %{
        "id" => "PVTI_def",
        "content" => %{
          "__typename" => "PullRequest",
          "id" => "PR_456",
          "title" => "Add feature"
        },
        "fieldValues" => %{"nodes" => []}
      }

      item = ProjectItem.from_graphql(data)

      assert item.content_type == :pull_request
      assert item.content_id == "PR_456"
      assert item.field_values == %{}
    end

    test "parses a draft issue" do
      data = %{
        "id" => "PVTI_ghi",
        "content" => %{
          "__typename" => "DraftIssue",
          "id" => "DI_789",
          "title" => "TODO: Research"
        }
      }

      item = ProjectItem.from_graphql(data)

      assert item.content_type == :draft_issue
      assert item.title == "TODO: Research"
    end

    test "handles missing content gracefully" do
      data = %{"id" => "PVTI_empty", "content" => %{}}

      item = ProjectItem.from_graphql(data)

      assert item.id == "PVTI_empty"
      assert item.content_type == :unknown
      assert item.content_id == nil
    end
  end
end
