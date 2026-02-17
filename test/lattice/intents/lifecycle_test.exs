defmodule Lattice.Intents.LifecycleTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Lifecycle

  @valid_source %{type: :sprite, id: "sprite-001"}

  defp new_intent(state) do
    {:ok, intent} =
      Intent.new_maintenance(@valid_source, summary: "Test", payload: %{})

    # For testing non-proposed states, manually set the state
    if state == :proposed do
      intent
    else
      %{intent | state: state}
    end
  end

  # ── Valid Transitions ────────────────────────────────────────────────

  describe "transition/3 valid paths" do
    test "proposed → classified" do
      intent = new_intent(:proposed)
      assert {:ok, updated} = Lifecycle.transition(intent, :classified)
      assert updated.state == :classified
    end

    test "classified → awaiting_approval" do
      intent = new_intent(:classified)
      assert {:ok, updated} = Lifecycle.transition(intent, :awaiting_approval)
      assert updated.state == :awaiting_approval
    end

    test "classified → approved" do
      intent = new_intent(:classified)
      assert {:ok, updated} = Lifecycle.transition(intent, :approved)
      assert updated.state == :approved
    end

    test "awaiting_approval → approved" do
      intent = new_intent(:awaiting_approval)
      assert {:ok, updated} = Lifecycle.transition(intent, :approved)
      assert updated.state == :approved
    end

    test "awaiting_approval → rejected" do
      intent = new_intent(:awaiting_approval)
      assert {:ok, updated} = Lifecycle.transition(intent, :rejected)
      assert updated.state == :rejected
    end

    test "awaiting_approval → canceled" do
      intent = new_intent(:awaiting_approval)
      assert {:ok, updated} = Lifecycle.transition(intent, :canceled)
      assert updated.state == :canceled
    end

    test "approved → running" do
      intent = new_intent(:approved)
      assert {:ok, updated} = Lifecycle.transition(intent, :running)
      assert updated.state == :running
    end

    test "approved → canceled" do
      intent = new_intent(:approved)
      assert {:ok, updated} = Lifecycle.transition(intent, :canceled)
      assert updated.state == :canceled
    end

    test "running → completed" do
      intent = new_intent(:running)
      assert {:ok, updated} = Lifecycle.transition(intent, :completed)
      assert updated.state == :completed
    end

    test "running → failed" do
      intent = new_intent(:running)
      assert {:ok, updated} = Lifecycle.transition(intent, :failed)
      assert updated.state == :failed
    end
  end

  # ── Invalid Transitions ──────────────────────────────────────────────

  describe "transition/3 invalid paths" do
    test "proposed cannot skip to approved" do
      intent = new_intent(:proposed)

      assert {:error, {:invalid_transition, %{from: :proposed, to: :approved}}} =
               Lifecycle.transition(intent, :approved)
    end

    test "proposed cannot go to running" do
      intent = new_intent(:proposed)

      assert {:error, {:invalid_transition, %{from: :proposed, to: :running}}} =
               Lifecycle.transition(intent, :running)
    end

    test "completed is terminal" do
      intent = new_intent(:completed)

      assert {:error, {:invalid_transition, %{from: :completed, to: :running}}} =
               Lifecycle.transition(intent, :running)
    end

    test "failed is terminal" do
      intent = new_intent(:failed)

      assert {:error, {:invalid_transition, %{from: :failed, to: :running}}} =
               Lifecycle.transition(intent, :running)
    end

    test "rejected is terminal" do
      intent = new_intent(:rejected)

      assert {:error, {:invalid_transition, %{from: :rejected, to: :proposed}}} =
               Lifecycle.transition(intent, :proposed)
    end

    test "canceled is terminal" do
      intent = new_intent(:canceled)

      assert {:error, {:invalid_transition, %{from: :canceled, to: :proposed}}} =
               Lifecycle.transition(intent, :proposed)
    end

    test "rejects invalid target state" do
      intent = new_intent(:proposed)

      assert {:error, {:invalid_state, :nonexistent}} =
               Lifecycle.transition(intent, :nonexistent)
    end

    test "running cannot go back to approved" do
      intent = new_intent(:running)

      assert {:error, {:invalid_transition, %{from: :running, to: :approved}}} =
               Lifecycle.transition(intent, :approved)
    end
  end

  # ── Timestamp Updates ────────────────────────────────────────────────

  describe "lifecycle timestamps" do
    test "classified sets classified_at" do
      intent = new_intent(:proposed)
      assert intent.classified_at == nil

      {:ok, updated} = Lifecycle.transition(intent, :classified)
      assert %DateTime{} = updated.classified_at
    end

    test "approved sets approved_at" do
      intent = new_intent(:classified)
      {:ok, updated} = Lifecycle.transition(intent, :approved)
      assert %DateTime{} = updated.approved_at
    end

    test "running sets started_at" do
      intent = new_intent(:approved)
      {:ok, updated} = Lifecycle.transition(intent, :running)
      assert %DateTime{} = updated.started_at
    end

    test "completed sets completed_at" do
      intent = new_intent(:running)
      {:ok, updated} = Lifecycle.transition(intent, :completed)
      assert %DateTime{} = updated.completed_at
    end

    test "failed sets completed_at" do
      intent = new_intent(:running)
      {:ok, updated} = Lifecycle.transition(intent, :failed)
      assert %DateTime{} = updated.completed_at
    end

    test "updated_at is refreshed on transition" do
      intent = new_intent(:proposed)
      {:ok, updated} = Lifecycle.transition(intent, :classified)
      assert DateTime.compare(updated.updated_at, intent.updated_at) in [:gt, :eq]
    end
  end

  # ── Transition Log ──────────────────────────────────────────────────

  describe "transition log" do
    test "records transition entry" do
      intent = new_intent(:proposed)
      {:ok, updated} = Lifecycle.transition(intent, :classified, actor: "system", reason: "auto")

      assert [entry] = updated.transition_log
      assert entry.from == :proposed
      assert entry.to == :classified
      assert entry.actor == "system"
      assert entry.reason == "auto"
      assert %DateTime{} = entry.timestamp
    end

    test "prepends new entries" do
      intent = new_intent(:proposed)
      {:ok, intent} = Lifecycle.transition(intent, :classified)
      intent = %{intent | state: :classified}
      {:ok, intent} = Lifecycle.transition(intent, :approved)

      assert [second, first] = intent.transition_log
      assert first.from == :proposed
      assert first.to == :classified
      assert second.from == :classified
      assert second.to == :approved
    end

    test "defaults actor and reason to nil" do
      intent = new_intent(:proposed)
      {:ok, updated} = Lifecycle.transition(intent, :classified)

      [entry] = updated.transition_log
      assert entry.actor == nil
      assert entry.reason == nil
    end
  end

  # ── valid_transitions/1 ─────────────────────────────────────────────

  describe "valid_transitions/1" do
    test "returns valid targets for proposed" do
      assert Lifecycle.valid_transitions(:proposed) == [:classified]
    end

    test "returns valid targets for classified" do
      assert Lifecycle.valid_transitions(:classified) == [:awaiting_approval, :approved]
    end

    test "returns empty list for terminal states" do
      assert Lifecycle.valid_transitions(:completed) == []
      assert Lifecycle.valid_transitions(:failed) == []
      assert Lifecycle.valid_transitions(:rejected) == []
      assert Lifecycle.valid_transitions(:canceled) == []
    end

    test "returns error for invalid state" do
      assert {:error, {:invalid_state, :bogus}} = Lifecycle.valid_transitions(:bogus)
    end
  end

  # ── terminal?/1 ─────────────────────────────────────────────────────

  describe "terminal?/1" do
    test "completed is terminal" do
      assert Lifecycle.terminal?(:completed)
    end

    test "failed is terminal" do
      assert Lifecycle.terminal?(:failed)
    end

    test "rejected is terminal" do
      assert Lifecycle.terminal?(:rejected)
    end

    test "canceled is terminal" do
      assert Lifecycle.terminal?(:canceled)
    end

    test "proposed is not terminal" do
      refute Lifecycle.terminal?(:proposed)
    end

    test "running is not terminal" do
      refute Lifecycle.terminal?(:running)
    end

    test "approved is not terminal" do
      refute Lifecycle.terminal?(:approved)
    end
  end

  # ── valid_states/0 ──────────────────────────────────────────────────

  describe "valid_states/0" do
    test "returns all 9 states" do
      states = Lifecycle.valid_states()
      assert length(states) == 9
      assert :proposed in states
      assert :classified in states
      assert :awaiting_approval in states
      assert :approved in states
      assert :running in states
      assert :completed in states
      assert :failed in states
      assert :rejected in states
      assert :canceled in states
    end
  end
end
