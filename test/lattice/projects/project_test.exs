defmodule Lattice.Projects.ProjectTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Projects.Project

  setup do
    # Clean up any existing projects
    {:ok, projects} = Project.list()
    Enum.each(projects, fn p -> Project.delete(p.id) end)
    :ok
  end

  describe "create/3" do
    test "creates a new project" do
      {:ok, project} = Project.create("Test Project", "A test project", repo: "org/repo")
      assert project.name == "Test Project"
      assert project.description == "A test project"
      assert project.repo == "org/repo"
      assert is_binary(project.id)
    end
  end

  describe "get/1" do
    test "retrieves a project by ID" do
      {:ok, created} = Project.create("Get Test", "test")
      {:ok, fetched} = Project.get(created.id)
      assert fetched.name == "Get Test"
    end

    test "returns error for nonexistent project" do
      assert {:error, :not_found} = Project.get("nonexistent")
    end
  end

  describe "list/0" do
    test "lists all projects" do
      Project.create("Project 1", "first")
      Project.create("Project 2", "second")
      {:ok, projects} = Project.list()
      assert length(projects) == 2
    end
  end

  describe "add_epic/4" do
    test "adds an epic to a project" do
      {:ok, project} = Project.create("Epic Test", "test")
      {:ok, updated} = Project.add_epic(project.id, "Epic 1", "First epic")
      assert length(updated.epics) == 1
      assert hd(updated.epics).title == "Epic 1"
    end
  end

  describe "add_task/4" do
    test "adds a task to an epic" do
      {:ok, project} = Project.create("Task Test", "test")
      {:ok, with_epic} = Project.add_epic(project.id, "Epic 1", "desc")
      epic_id = hd(with_epic.epics).id

      {:ok, updated} = Project.add_task(project.id, epic_id, "Do the thing")
      tasks = hd(updated.epics).tasks
      assert length(tasks) == 1
      assert hd(tasks).description == "Do the thing"
      assert hd(tasks).status == :pending
    end
  end

  describe "progress/1" do
    test "computes progress from task statuses" do
      {:ok, project} = Project.create("Progress Test", "test")
      {:ok, with_epic} = Project.add_epic(project.id, "Epic", "desc")
      epic = hd(with_epic.epics)

      tasks = [
        %{
          id: "t1",
          description: "Done",
          intent_id: nil,
          status: :completed,
          blocks: [],
          blocked_by: []
        },
        %{
          id: "t2",
          description: "WIP",
          intent_id: nil,
          status: :in_progress,
          blocks: [],
          blocked_by: []
        },
        %{
          id: "t3",
          description: "Todo",
          intent_id: nil,
          status: :pending,
          blocks: [],
          blocked_by: []
        }
      ]

      {:ok, updated} =
        Project.update(project.id, %{
          epics: [%{epic | tasks: tasks}]
        })

      progress = Project.progress(updated)
      assert progress.total_tasks == 3
      assert progress.completed == 1
      assert progress.in_progress == 1
      assert progress.pending == 1
      assert progress.percent == 33.3
    end

    test "returns 0% for empty project" do
      {:ok, project} = Project.create("Empty", "test")
      progress = Project.progress(project)
      assert progress.total_tasks == 0
      assert progress.percent == 0.0
    end
  end

  describe "delete/1" do
    test "deletes a project" do
      {:ok, project} = Project.create("Delete Test", "test")
      Project.delete(project.id)
      assert {:error, :not_found} = Project.get(project.id)
    end
  end
end
