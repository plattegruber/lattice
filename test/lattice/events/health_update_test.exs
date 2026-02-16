defmodule Lattice.Events.HealthUpdateTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Events.HealthUpdate

  describe "new/4" do
    test "creates a health update with required fields" do
      assert {:ok, event} = HealthUpdate.new("sprite-001", :healthy, 15)

      assert event.sprite_id == "sprite-001"
      assert event.status == :healthy
      assert event.check_duration_ms == 15
      assert event.message == nil
      assert %DateTime{} = event.timestamp
    end

    test "accepts optional message" do
      assert {:ok, event} =
               HealthUpdate.new("sprite-001", :degraded, 200, message: "high latency")

      assert event.message == "high latency"
    end

    test "accepts optional timestamp" do
      ts = ~U[2026-01-15 10:00:00Z]
      assert {:ok, event} = HealthUpdate.new("sprite-001", :unhealthy, 5000, timestamp: ts)
      assert event.timestamp == ts
    end

    test "accepts all valid statuses" do
      for status <- [:healthy, :degraded, :unhealthy] do
        assert {:ok, _event} = HealthUpdate.new("sprite-001", status, 10)
      end
    end

    test "rejects invalid status" do
      assert {:error, {:invalid_status, :unknown}} =
               HealthUpdate.new("sprite-001", :unknown, 10)
    end

    test "returns valid statuses through valid_statuses/0" do
      assert HealthUpdate.valid_statuses() == [:healthy, :degraded, :unhealthy]
    end
  end
end
