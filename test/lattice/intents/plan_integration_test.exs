defmodule Lattice.Intents.PlanIntegrationTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Plan
  alias Lattice.Intents.Plan.Step
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  @valid_source %{type: :operator, id: "test-op"}

  setup do
    StoreETS.reset()
    :ok
  end

  # ── Pipeline.attach_plan/2 ─────────────────────────────────────────

  describe "Pipeline.attach_plan/2" do
    test "attaches a plan to a proposed intent" do
      {:ok, intent} =
        Intent.new_maintenance(@valid_source, summary: "Update image", payload: %{})

      {:ok, stored} = Store.create(intent)

      {:ok, s1} = Step.new("Pull image", id: "s1")
      {:ok, s2} = Step.new("Restart app", id: "s2", skill: "fly_restart")
      {:ok, plan} = Plan.new("Update Workflow", [s1, s2], :operator)

      assert {:ok, updated} = Pipeline.attach_plan(stored.id, plan)
      assert updated.plan.title == "Update Workflow"
      assert length(updated.plan.steps) == 2
      assert updated.plan.source == :operator
    end

    test "returns :immutable when intent is approved" do
      {:ok, intent} =
        Intent.new_maintenance(@valid_source, summary: "Update", payload: %{})

      {:ok, _} = Pipeline.propose(intent)
      # It auto-advances to approved (maintenance is safe)
      {:ok, fetched} = Store.get(intent.id)
      assert fetched.state == :approved

      {:ok, s1} = Step.new("Step")
      {:ok, plan} = Plan.new("Late Plan", [s1])

      assert {:error, :immutable} = Pipeline.attach_plan(intent.id, plan)
    end

    test "plan persists after re-fetching" do
      {:ok, intent} =
        Intent.new_maintenance(@valid_source, summary: "Test", payload: %{})

      {:ok, stored} = Store.create(intent)

      {:ok, s1} = Step.new("Step one", id: "s1")
      {:ok, plan} = Plan.new("Persistent Plan", [s1])

      {:ok, _} = Pipeline.attach_plan(stored.id, plan)

      {:ok, refetched} = Store.get(stored.id)
      assert refetched.plan.title == "Persistent Plan"
      assert length(refetched.plan.steps) == 1
    end
  end

  # ── Store.update_plan_step/4 ───────────────────────────────────────

  describe "Store.update_plan_step/4" do
    setup do
      {:ok, intent} =
        Intent.new_action(@valid_source,
          summary: "Deploy",
          payload: %{"capability" => "fly", "operation" => "deploy"},
          affected_resources: ["app"],
          expected_side_effects: ["restart"]
        )

      {:ok, stored} = Store.create(intent)

      {:ok, s1} = Step.new("Build", id: "s1")
      {:ok, s2} = Step.new("Deploy", id: "s2")
      {:ok, plan} = Plan.new("Deploy Steps", [s1, s2])

      {:ok, with_plan} = Store.update(stored.id, %{plan: plan})

      %{intent_id: with_plan.id}
    end

    test "updates step status", %{intent_id: id} do
      assert {:ok, updated} = Store.update_plan_step(id, "s1", :running)
      assert Enum.at(updated.plan.steps, 0).status == :running
      assert Enum.at(updated.plan.steps, 1).status == :pending
    end

    test "updates step with output", %{intent_id: id} do
      assert {:ok, updated} = Store.update_plan_step(id, "s1", :completed, "build ok")
      assert Enum.at(updated.plan.steps, 0).output == "build ok"
    end

    test "increments plan version", %{intent_id: id} do
      {:ok, v1} = Store.get(id)
      assert v1.plan.version == 1

      {:ok, v2} = Store.update_plan_step(id, "s1", :running)
      assert v2.plan.version == 2

      {:ok, v3} = Store.update_plan_step(id, "s1", :completed)
      assert v3.plan.version == 3
    end

    test "returns :no_plan when intent has no plan" do
      {:ok, intent} =
        Intent.new_maintenance(@valid_source, summary: "No plan", payload: %{})

      {:ok, stored} = Store.create(intent)

      assert {:error, :no_plan} = Store.update_plan_step(stored.id, "s1", :running)
    end

    test "returns :step_not_found for unknown step", %{intent_id: id} do
      assert {:error, {:step_not_found, "s99"}} =
               Store.update_plan_step(id, "s99", :running)
    end

    test "returns :not_found for unknown intent" do
      assert {:error, :not_found} = Store.update_plan_step("bogus", "s1", :running)
    end

    test "bypasses frozen-field checks when intent is approved", %{intent_id: id} do
      # Manually transition to approved state to test
      Store.update(id, %{
        state: :classified,
        classification: :safe,
        actor: :test,
        reason: "test"
      })

      Store.update(id, %{state: :approved, actor: :test, reason: "test"})

      # update_plan_step should still work even though plan is frozen
      assert {:ok, updated} = Store.update_plan_step(id, "s1", :running)
      assert Enum.at(updated.plan.steps, 0).status == :running
    end
  end

  # ── Plan in frozen fields ──────────────────────────────────────────

  describe "plan immutability" do
    test "plan field is frozen after approval" do
      {:ok, intent} =
        Intent.new_maintenance(@valid_source, summary: "Freeze test", payload: %{})

      {:ok, _} = Pipeline.propose(intent)
      # Auto-approved (maintenance is safe)

      {:ok, s1} = Step.new("Late step")
      {:ok, new_plan} = Plan.new("Late Plan", [s1])

      assert {:error, :immutable} = Store.update(intent.id, %{plan: new_plan})
    end
  end
end
