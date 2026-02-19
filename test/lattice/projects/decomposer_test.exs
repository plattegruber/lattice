defmodule Lattice.Projects.DecomposerTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Projects.Decomposer

  describe "decompose/2" do
    test "decomposes checklist items into epics" do
      description = """
      ## Setup
      - [ ] Install dependencies
      - [ ] Configure database

      ## Implementation
      - [ ] Build the API
      - [ ] Add tests
      """

      epics = Decomposer.decompose(description)
      assert length(epics) == 2
      assert hd(epics).title == "Setup"
      assert length(hd(epics).tasks) == 2
    end

    test "applies sequential dependencies" do
      description = """
      ## Tasks
      - [ ] First thing
      - [ ] Second thing
      - [ ] Third thing
      """

      [epic] = Decomposer.decompose(description)
      tasks = epic.tasks

      # First task has no dependencies
      assert Enum.at(tasks, 0).blocked_by == []
      # Second task blocked by first
      assert Enum.at(tasks, 1).blocked_by == [Enum.at(tasks, 0).id]
      # Third task blocked by second
      assert Enum.at(tasks, 2).blocked_by == [Enum.at(tasks, 1).id]
    end

    test "handles bullet points without checkboxes" do
      description = """
      ## Work
      - Do this
      - Do that
      """

      [epic] = Decomposer.decompose(description)
      assert length(epic.tasks) == 2
    end
  end

  describe "seed_issue?/1" do
    test "detects project label" do
      issue = %{"labels" => [%{"name" => "project"}], "body" => ""}
      assert Decomposer.seed_issue?(issue)
    end

    test "detects epic label" do
      issue = %{"labels" => [%{"name" => "epic"}], "body" => ""}
      assert Decomposer.seed_issue?(issue)
    end

    test "detects checklist + sections" do
      issue = %{
        "labels" => [],
        "body" => """
        ## Phase 1
        - [ ] Task 1
        ## Phase 2
        - [ ] Task 2
        """
      }

      assert Decomposer.seed_issue?(issue)
    end

    test "rejects simple issues" do
      issue = %{"labels" => [], "body" => "Fix the bug in login"}
      refute Decomposer.seed_issue?(issue)
    end
  end

  describe "extract_checklist/1" do
    test "extracts checklist items" do
      body = """
      Some text
      - [ ] Task one
      - [x] Task two
      - [ ] Task three
      More text
      """

      items = Decomposer.extract_checklist(body)
      assert items == ["Task one", "Task two", "Task three"]
    end

    test "returns empty for no checklist" do
      assert Decomposer.extract_checklist("No checklist here") == []
    end
  end
end
