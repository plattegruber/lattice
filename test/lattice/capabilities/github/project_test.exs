defmodule Lattice.Capabilities.GitHub.ProjectTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Project

  describe "from_graphql/1" do
    test "parses a project node with fields" do
      data = %{
        "id" => "PVT_abc123",
        "title" => "Sprint Board",
        "shortDescription" => "Current sprint",
        "url" => "https://github.com/orgs/test/projects/1",
        "fields" => %{
          "nodes" => [
            %{"id" => "PVTF_1", "name" => "Status", "dataType" => "SINGLE_SELECT"},
            %{"id" => "PVTF_2", "name" => "Priority", "dataType" => "SINGLE_SELECT"}
          ]
        }
      }

      project = Project.from_graphql(data)

      assert %Project{} = project
      assert project.id == "PVT_abc123"
      assert project.title == "Sprint Board"
      assert project.description == "Current sprint"
      assert project.url == "https://github.com/orgs/test/projects/1"
      assert length(project.fields) == 2
      assert Enum.any?(project.fields, &(&1.name == "Status"))
    end

    test "parses a project node without fields" do
      data = %{
        "id" => "PVT_xyz",
        "title" => "Backlog",
        "shortDescription" => nil,
        "url" => nil
      }

      project = Project.from_graphql(data)

      assert project.id == "PVT_xyz"
      assert project.title == "Backlog"
      assert project.fields == []
    end
  end
end
