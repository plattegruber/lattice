defmodule Lattice.Capabilities.GitHubProjectsTest do
  use ExUnit.Case, async: true

  import Mox

  @moduletag :unit

  alias Lattice.Capabilities.GitHub

  setup :verify_on_exit!

  describe "list_projects/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_projects, fn _opts ->
        {:ok,
         [
           %{id: "PVT_1", title: "Sprint", fields: []},
           %{id: "PVT_2", title: "Backlog", fields: []}
         ]}
      end)

      assert {:ok, projects} = GitHub.list_projects()
      assert length(projects) == 2
    end
  end

  describe "get_project/1" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_project, fn project_id ->
        assert project_id == "PVT_abc"
        {:ok, %{id: "PVT_abc", title: "Sprint", fields: []}}
      end)

      assert {:ok, project} = GitHub.get_project("PVT_abc")
      assert project.title == "Sprint"
    end
  end

  describe "list_project_items/2" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_project_items, fn project_id, _opts ->
        assert project_id == "PVT_abc"
        {:ok, [%{id: "PVTI_1", content_type: :issue}]}
      end)

      assert {:ok, items} = GitHub.list_project_items("PVT_abc")
      assert length(items) == 1
    end
  end

  describe "add_to_project/2" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:add_to_project, fn project_id, content_id ->
        assert project_id == "PVT_abc"
        assert content_id == "I_123"
        {:ok, %{item_id: "PVTI_new"}}
      end)

      assert {:ok, result} = GitHub.add_to_project("PVT_abc", "I_123")
      assert result.item_id == "PVTI_new"
    end
  end

  describe "update_project_item_field/4" do
    test "delegates to the configured implementation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:update_project_item_field, fn project_id, item_id, field_id, value ->
        assert project_id == "PVT_abc"
        assert item_id == "PVTI_1"
        assert field_id == "PVTF_status"
        assert value == "opt_done"
        {:ok, %{item_id: "PVTI_1"}}
      end)

      assert {:ok, _} =
               GitHub.update_project_item_field("PVT_abc", "PVTI_1", "PVTF_status", "opt_done")
    end
  end
end
