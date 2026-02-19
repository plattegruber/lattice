defmodule Lattice.Planning.ExecutorTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Plan
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS
  alias Lattice.Planning.Executor

  setup do
    StoreETS.reset()
    :ok
  end

  defp new_intent_with_plan do
    {:ok, intent} =
      Intent.new_action(%{type: :system, id: "sys"},
        summary: "Fix the login bug",
        payload: %{"repo" => "plattegruber/lattice"},
        affected_resources: ["code"],
        expected_side_effects: ["code_change"]
      )

    {:ok, plan} =
      Plan.new("Fix login bug", [
        [description: "Analyze the issue"],
        [description: "Implement the fix"],
        [description: "Write tests"]
      ])

    intent = %{intent | kind: :issue_triage, plan: plan, state: :approved}

    # Store the parent
    {:ok, stored} = StoreETS.create(intent)
    stored
  end

  describe "execute_plan/1" do
    test "creates child intents for each plan step" do
      parent = new_intent_with_plan()
      assert {:ok, children} = Executor.execute_plan(parent)
      assert length(children) == 3

      summaries = Enum.map(children, & &1.summary)
      assert "Analyze the issue" in summaries
      assert "Implement the fix" in summaries
      assert "Write tests" in summaries
    end

    test "child intents reference parent via metadata" do
      parent = new_intent_with_plan()
      {:ok, [child | _]} = Executor.execute_plan(parent)
      assert child.metadata["parent_intent_id"] == parent.id
    end

    test "returns error when no plan attached" do
      {:ok, intent} =
        Intent.new_action(%{type: :system, id: "sys"},
          summary: "No plan",
          payload: %{},
          affected_resources: ["code"],
          expected_side_effects: ["code_change"]
        )

      assert {:error, :no_plan} = Executor.execute_plan(intent)
    end
  end

  describe "list_children/1" do
    test "lists children for a parent" do
      parent = new_intent_with_plan()
      {:ok, _children} = Executor.execute_plan(parent)

      listed = Executor.list_children(parent.id)
      assert length(listed) == 3
    end

    test "returns empty list when no children" do
      assert Executor.list_children("nonexistent") == []
    end
  end

  describe "progress/1" do
    test "computes progress summary" do
      parent = new_intent_with_plan()
      {:ok, children} = Executor.execute_plan(parent)

      # Complete one child through the full state machine
      child = hd(children)

      # Walk from current state to completed
      case child.state do
        :awaiting_approval ->
          {:ok, approved} = Store.update(child.id, %{state: :approved})
          {:ok, running} = Store.update(approved.id, %{state: :running})
          {:ok, _} = Store.update(running.id, %{state: :completed})

        :approved ->
          {:ok, running} = Store.update(child.id, %{state: :running})
          {:ok, _} = Store.update(running.id, %{state: :completed})
      end

      progress = Executor.progress(parent.id)
      assert progress.total == 3
      assert progress.completed == 1
      assert progress.percent == 33.3
    end
  end

  describe "all_children_completed?/1" do
    test "returns false when children pending" do
      parent = new_intent_with_plan()
      {:ok, _children} = Executor.execute_plan(parent)

      refute Executor.all_children_completed?(parent.id)
    end

    test "returns false when no children" do
      refute Executor.all_children_completed?("nonexistent")
    end
  end
end
