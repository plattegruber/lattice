defmodule Lattice.Events.StateChangeTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Events.StateChange

  describe "new/4" do
    test "creates a state change event with required fields" do
      assert {:ok, event} = StateChange.new("sprite-001", :cold, :warm)

      assert event.sprite_id == "sprite-001"
      assert event.from_state == :cold
      assert event.to_state == :warm
      assert event.reason == nil
      assert %DateTime{} = event.timestamp
    end

    test "accepts an optional reason" do
      assert {:ok, event} =
               StateChange.new("sprite-001", :running, :cold, reason: "connection lost")

      assert event.reason == "connection lost"
    end

    test "accepts an optional timestamp" do
      ts = ~U[2026-01-15 10:00:00Z]
      assert {:ok, event} = StateChange.new("sprite-001", :warm, :running, timestamp: ts)
      assert event.timestamp == ts
    end

    test "rejects invalid from_state" do
      assert {:error, {:invalid_state, :nonexistent}} =
               StateChange.new("sprite-001", :nonexistent, :warm)
    end

    test "rejects invalid to_state" do
      assert {:error, {:invalid_state, :bogus}} =
               StateChange.new("sprite-001", :cold, :bogus)
    end

    test "returns all valid states through valid_states/0" do
      assert StateChange.valid_states() == [:cold, :warm, :running]
    end
  end

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(StateChange, %{sprite_id: "sprite-001"})
      end
    end
  end
end
