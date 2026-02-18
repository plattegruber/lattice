defmodule Lattice.Intents.PlanTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Intents.Plan
  alias Lattice.Intents.Plan.Step

  describe "new/3" do
    test "creates a plan with step structs" do
      {:ok, s1} = Step.new("Step one")
      {:ok, s2} = Step.new("Step two", skill: "deployer")

      assert {:ok, plan} = Plan.new("Deploy Plan", [s1, s2])

      assert plan.title == "Deploy Plan"
      assert length(plan.steps) == 2
      assert plan.source == :agent
      assert plan.version == 1
      assert plan.rendered_markdown =~ "Deploy Plan"
      assert plan.rendered_markdown =~ "Step one"
      assert plan.rendered_markdown =~ "Step two"
      assert plan.rendered_markdown =~ "`[deployer]`"
    end

    test "creates a plan with keyword step definitions" do
      steps = [
        [description: "Build release"],
        [description: "Run tests", skill: "test_runner"]
      ]

      assert {:ok, plan} = Plan.new("CI Plan", steps, :system)

      assert plan.source == :system
      assert length(plan.steps) == 2
      assert Enum.at(plan.steps, 0).description == "Build release"
      assert Enum.at(plan.steps, 1).skill == "test_runner"
    end

    test "rejects step without description" do
      steps = [[skill: "deployer"]]

      assert {:error, {:missing_step_description, _}} = Plan.new("Bad Plan", steps)
    end

    test "rejects invalid step type" do
      assert {:error, {:invalid_step, "not a step"}} = Plan.new("Bad", ["not a step"])
    end
  end

  describe "update_step_status/4" do
    setup do
      {:ok, s1} = Step.new("Step one", id: "s1")
      {:ok, s2} = Step.new("Step two", id: "s2")
      {:ok, plan} = Plan.new("Test Plan", [s1, s2])
      %{plan: plan}
    end

    test "updates a step to running", %{plan: plan} do
      assert {:ok, updated} = Plan.update_step_status(plan, "s1", :running)
      assert Enum.at(updated.steps, 0).status == :running
      assert Enum.at(updated.steps, 1).status == :pending
      assert updated.version == 2
    end

    test "updates a step to completed with output", %{plan: plan} do
      assert {:ok, updated} = Plan.update_step_status(plan, "s1", :completed, "done!")
      assert Enum.at(updated.steps, 0).status == :completed
      assert Enum.at(updated.steps, 0).output == "done!"
      assert updated.rendered_markdown =~ "[x]"
    end

    test "updates a step to failed", %{plan: plan} do
      assert {:ok, updated} = Plan.update_step_status(plan, "s2", :failed, "timeout")
      assert Enum.at(updated.steps, 1).status == :failed
      assert Enum.at(updated.steps, 1).output == "timeout"
      assert updated.rendered_markdown =~ "[!]"
    end

    test "returns error for unknown step", %{plan: plan} do
      assert {:error, {:step_not_found, "s99"}} =
               Plan.update_step_status(plan, "s99", :running)
    end

    test "returns error for invalid status", %{plan: plan} do
      assert {:error, {:invalid_step_status, :invalid}} =
               Plan.update_step_status(plan, "s1", :invalid)
    end

    test "preserves existing output when new output is nil", %{plan: plan} do
      {:ok, with_output} = Plan.update_step_status(plan, "s1", :running, "started")
      {:ok, updated} = Plan.update_step_status(with_output, "s1", :completed)
      assert Enum.at(updated.steps, 0).output == "started"
    end

    test "re-renders markdown on update", %{plan: plan} do
      {:ok, updated} = Plan.update_step_status(plan, "s1", :completed)
      assert updated.rendered_markdown =~ "[x]"
      assert updated.rendered_markdown =~ "[ ]"
    end
  end

  describe "valid_sources/0" do
    test "returns agent, operator, system" do
      assert Plan.valid_sources() == [:agent, :operator, :system]
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips a plan" do
      {:ok, s1} = Step.new("Step one", id: "s1", skill: "builder")
      {:ok, plan} = Plan.new("Round Trip", [s1], :operator)

      map = Plan.to_map(plan)

      assert map.title == "Round Trip"
      assert map.source == :operator
      assert map.version == 1
      assert length(map.steps) == 1
      assert hd(map.steps).id == "s1"

      # from_map expects string keys
      string_map = %{
        "title" => map.title,
        "steps" =>
          Enum.map(map.steps, fn s ->
            %{
              "id" => s.id,
              "description" => s.description,
              "skill" => s.skill,
              "inputs" => s.inputs,
              "status" => to_string(s.status)
            }
          end),
        "source" => to_string(map.source),
        "version" => map.version,
        "rendered_markdown" => map.rendered_markdown
      }

      assert {:ok, restored} = Plan.from_map(string_map)
      assert restored.title == "Round Trip"
      assert restored.source == :operator
      assert length(restored.steps) == 1
    end

    test "from_map returns error for invalid input" do
      assert {:error, :invalid_plan} = Plan.from_map(%{})
      assert {:error, :invalid_plan} = Plan.from_map(%{"title" => "x"})
    end

    test "from_map returns error for invalid source" do
      map = %{"title" => "T", "steps" => [], "source" => "bogus"}
      assert {:error, {:invalid_plan_source, "bogus"}} = Plan.from_map(map)
    end
  end

  describe "render_markdown/2" do
    test "renders checkboxes based on status" do
      {:ok, s1} = Step.new("Done", id: "s1")
      {:ok, s2} = Step.new("In Progress", id: "s2")
      {:ok, s3} = Step.new("Pending", id: "s3")

      s1 = %{s1 | status: :completed}
      s2 = %{s2 | status: :running}

      md = Plan.render_markdown("My Plan", [s1, s2, s3])

      assert md =~ "## My Plan"
      assert md =~ "1. [x] Done"
      assert md =~ "2. [~] In Progress"
      assert md =~ "3. [ ] Pending"
    end
  end
end
