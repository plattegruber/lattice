defmodule Lattice.Intents.Plan.StepTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Intents.Plan.Step

  describe "new/2" do
    test "creates a step with description and generated ID" do
      assert {:ok, step} = Step.new("Deploy the app")
      assert step.description == "Deploy the app"
      assert String.starts_with?(step.id, "step_")
      assert step.status == :pending
      assert step.inputs == %{}
      assert step.skill == nil
      assert step.output == nil
    end

    test "accepts optional skill, inputs, and custom ID" do
      assert {:ok, step} =
               Step.new("Run tests",
                 id: "custom-id",
                 skill: "test_runner",
                 inputs: %{"timeout" => 30}
               )

      assert step.id == "custom-id"
      assert step.skill == "test_runner"
      assert step.inputs == %{"timeout" => 30}
    end
  end

  describe "valid_statuses/0" do
    test "returns all valid statuses" do
      statuses = Step.valid_statuses()
      assert :pending in statuses
      assert :running in statuses
      assert :completed in statuses
      assert :failed in statuses
      assert :skipped in statuses
      assert length(statuses) == 5
    end
  end

  describe "to_map/1" do
    test "converts step to a plain map" do
      {:ok, step} = Step.new("Build release", skill: "builder")

      map = Step.to_map(step)

      assert map.description == "Build release"
      assert map.skill == "builder"
      assert map.status == :pending
      assert map.inputs == %{}
      assert map.output == nil
      assert map.id == step.id
    end
  end

  describe "from_map/1" do
    test "reconstructs step from a string-keyed map" do
      map = %{
        "id" => "step_abc",
        "description" => "Deploy",
        "skill" => "deployer",
        "inputs" => %{"region" => "iad"},
        "status" => "completed",
        "output" => "deployed"
      }

      assert {:ok, step} = Step.from_map(map)
      assert step.id == "step_abc"
      assert step.description == "Deploy"
      assert step.skill == "deployer"
      assert step.inputs == %{"region" => "iad"}
      assert step.status == :completed
      assert step.output == "deployed"
    end

    test "defaults status to pending" do
      map = %{"id" => "s1", "description" => "Do thing"}

      assert {:ok, step} = Step.from_map(map)
      assert step.status == :pending
    end

    test "returns error for invalid map" do
      assert {:error, :invalid_step} = Step.from_map(%{})
      assert {:error, :invalid_step} = Step.from_map(%{"id" => "s1"})
      assert {:error, :invalid_step} = Step.from_map(%{"description" => "x"})
    end
  end
end
