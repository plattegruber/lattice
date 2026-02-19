defmodule Lattice.Intents.RollbackTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Rollback
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  @valid_source %{type: :sprite, id: "sprite-001"}

  setup do
    StoreETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_failed_intent(opts \\ []) do
    rollback_strategy = Keyword.get(opts, :rollback_strategy, "redeploy previous version")

    {:ok, intent} =
      Intent.new_action(@valid_source,
        summary: "Deploy new version",
        payload: %{"capability" => "fly", "operation" => "deploy"},
        affected_resources: ["app:lattice"],
        expected_side_effects: ["deploy v2"],
        rollback_strategy: rollback_strategy
      )

    {:ok, stored} = Store.create(intent)

    # Advance to :failed through proper lifecycle
    {:ok, classified} =
      Store.update(stored.id, %{
        state: :classified,
        classification: :safe,
        actor: :pipeline,
        reason: "classified"
      })

    {:ok, approved} =
      Store.update(classified.id, %{state: :approved, actor: :pipeline, reason: "approved"})

    {:ok, running} =
      Store.update(approved.id, %{state: :running, actor: :executor, reason: "started"})

    {:ok, failed} =
      Store.update(running.id, %{state: :failed, actor: :executor, reason: "execution failed"})

    failed
  end

  # ── Tests ────────────────────────────────────────────────────────────

  describe "propose_rollback/1" do
    test "creates a rollback intent for a failed intent with rollback_strategy" do
      failed = create_failed_intent()
      assert {:ok, rollback} = Rollback.propose_rollback(failed)

      assert rollback.kind == :maintenance
      assert rollback.rollback_for == failed.id
      assert rollback.source == %{type: :system, id: "auto-rollback"}
      assert rollback.summary == "Rollback: Deploy new version"
      assert rollback.payload["rollback_strategy"] == "redeploy previous version"
      assert rollback.payload["original_intent_id"] == failed.id
      assert rollback.affected_resources == ["app:lattice"]
    end

    test "stores reverse link on the original intent" do
      failed = create_failed_intent()
      {:ok, rollback} = Rollback.propose_rollback(failed)

      {:ok, updated_original} = Store.get(failed.id)
      assert updated_original.metadata[:rollback_intent_id] == rollback.id
    end

    test "returns error when intent has no rollback_strategy" do
      failed = create_failed_intent(rollback_strategy: nil)
      assert {:error, :no_rollback_strategy} = Rollback.propose_rollback(failed)
    end

    test "returns error when intent is not in :failed state" do
      {:ok, intent} =
        Intent.new_action(@valid_source,
          summary: "Do something",
          payload: %{"capability" => "sprites", "operation" => "list_sprites"},
          affected_resources: ["sprites"],
          expected_side_effects: ["none"],
          rollback_strategy: "undo"
        )

      {:ok, stored} = Store.create(intent)
      assert {:error, {:not_failed, :proposed}} = Rollback.propose_rollback(stored)
    end

    test "rollback intent goes through pipeline classification" do
      failed = create_failed_intent()
      {:ok, rollback} = Rollback.propose_rollback(failed)

      # Maintenance intents are classified as :safe and auto-approved
      assert rollback.state in [:approved, :classified]
      assert rollback.classification == :safe
    end

    test "emits telemetry on rollback proposal" do
      failed = create_failed_intent()

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:lattice, :intent, :rollback_proposed]
        ])

      {:ok, rollback} = Rollback.propose_rollback(failed)

      assert_received {[:lattice, :intent, :rollback_proposed], ^ref, _measurements,
                       %{original_intent: ^failed, rollback_intent: ^rollback}}
    end
  end

  describe "auto_propose_enabled?/0" do
    test "returns false by default" do
      refute Rollback.auto_propose_enabled?()
    end

    test "returns true when configured" do
      original = Application.get_env(:lattice, :intents, [])
      Application.put_env(:lattice, :intents, auto_propose_rollback: true)

      on_exit(fn -> Application.put_env(:lattice, :intents, original) end)

      assert Rollback.auto_propose_enabled?()
    end
  end

  describe "intent rollback_for field" do
    test "intent struct supports rollback_for field" do
      {:ok, intent} =
        Intent.new_maintenance(%{type: :system, id: "auto-rollback"},
          summary: "Rollback test",
          payload: %{"rollback_strategy" => "revert"},
          rollback_for: "int_original123"
        )

      assert intent.rollback_for == "int_original123"
    end

    test "rollback_for defaults to nil" do
      {:ok, intent} =
        Intent.new_action(@valid_source,
          summary: "Regular action",
          payload: %{"capability" => "sprites", "operation" => "list_sprites"},
          affected_resources: ["sprites"],
          expected_side_effects: ["none"]
        )

      assert intent.rollback_for == nil
    end
  end
end
