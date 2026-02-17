defmodule Lattice.Intents.ObservationTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Intents.Observation

  @sprite_id "sprite-001"

  # ── new/3 ──────────────────────────────────────────────────────────

  describe "new/3" do
    test "creates an observation with valid params" do
      assert {:ok, obs} =
               Observation.new(@sprite_id, :metric,
                 data: %{"cpu" => 85.2},
                 severity: :medium
               )

      assert obs.sprite_id == @sprite_id
      assert obs.type == :metric
      assert obs.data == %{"cpu" => 85.2}
      assert obs.severity == :medium
      assert String.starts_with?(obs.id, "obs_")
      assert %DateTime{} = obs.timestamp
    end

    test "defaults data to empty map" do
      assert {:ok, obs} = Observation.new(@sprite_id, :status)
      assert obs.data == %{}
    end

    test "defaults severity to :info" do
      assert {:ok, obs} = Observation.new(@sprite_id, :status)
      assert obs.severity == :info
    end

    test "accepts custom timestamp" do
      ts = ~U[2026-01-01 00:00:00Z]
      assert {:ok, obs} = Observation.new(@sprite_id, :metric, timestamp: ts)
      assert obs.timestamp == ts
    end

    test "creates observations for all valid types" do
      for type <- Observation.valid_types() do
        assert {:ok, obs} = Observation.new(@sprite_id, type)
        assert obs.type == type
      end
    end

    test "creates observations for all valid severities" do
      for severity <- Observation.valid_severities() do
        assert {:ok, obs} = Observation.new(@sprite_id, :metric, severity: severity)
        assert obs.severity == severity
      end
    end

    test "rejects invalid type" do
      assert {:error, {:invalid_type, :bogus}} = Observation.new(@sprite_id, :bogus)
    end

    test "rejects invalid severity" do
      assert {:error, {:invalid_severity, :bogus}} =
               Observation.new(@sprite_id, :metric, severity: :bogus)
    end

    test "rejects non-binary sprite_id" do
      assert {:error, {:invalid_sprite_id, 123}} = Observation.new(123, :metric)
    end
  end

  # ── ID Generation ──────────────────────────────────────────────────

  describe "id generation" do
    test "generates unique IDs with obs_ prefix" do
      {:ok, a} = Observation.new(@sprite_id, :metric)
      {:ok, b} = Observation.new(@sprite_id, :metric)

      assert String.starts_with?(a.id, "obs_")
      assert String.starts_with?(b.id, "obs_")
      assert a.id != b.id
    end
  end

  # ── Public Helpers ─────────────────────────────────────────────────

  describe "valid_types/0" do
    test "returns all four types" do
      assert Observation.valid_types() == [:metric, :anomaly, :status, :recommendation]
    end
  end

  describe "valid_severities/0" do
    test "returns all five severities" do
      assert Observation.valid_severities() == [:info, :low, :medium, :high, :critical]
    end
  end

  # ── Struct ─────────────────────────────────────────────────────────

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Observation, %{type: :metric})
      end
    end
  end
end
