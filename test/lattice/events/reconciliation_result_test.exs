defmodule Lattice.Events.ReconciliationResultTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Events.ReconciliationResult

  describe "new/4" do
    test "creates a reconciliation result with required fields" do
      assert {:ok, event} = ReconciliationResult.new("sprite-001", :success, 42)

      assert event.sprite_id == "sprite-001"
      assert event.outcome == :success
      assert event.duration_ms == 42
      assert event.details == nil
      assert %DateTime{} = event.timestamp
    end

    test "accepts optional details" do
      assert {:ok, event} =
               ReconciliationResult.new("sprite-001", :failure, 100, details: "API timeout")

      assert event.details == "API timeout"
    end

    test "accepts optional timestamp" do
      ts = ~U[2026-01-15 10:00:00Z]

      assert {:ok, event} =
               ReconciliationResult.new("sprite-001", :no_change, 5, timestamp: ts)

      assert event.timestamp == ts
    end

    test "accepts all valid outcomes" do
      for outcome <- [:success, :failure, :no_change] do
        assert {:ok, _event} = ReconciliationResult.new("sprite-001", outcome, 10)
      end
    end

    test "rejects invalid outcome" do
      assert {:error, {:invalid_outcome, :partial}} =
               ReconciliationResult.new("sprite-001", :partial, 10)
    end

    test "returns valid outcomes through valid_outcomes/0" do
      assert ReconciliationResult.valid_outcomes() == [:success, :failure, :no_change]
    end
  end
end
