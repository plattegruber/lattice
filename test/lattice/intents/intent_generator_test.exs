defmodule Lattice.Intents.IntentGeneratorTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.IntentGenerator
  alias Lattice.Intents.IntentGenerator.Default
  alias Lattice.Intents.Observation

  @sprite_id "sprite-gen-001"

  defp build_observation(type, severity, data \\ %{}) do
    {:ok, obs} = Observation.new(@sprite_id, type, severity: severity, data: data)
    obs
  end

  # ── Default Generator: Anomaly Rules ─────────────────────────────

  describe "Default.generate/1 anomaly rules" do
    test "high severity anomaly generates a maintenance intent" do
      obs = build_observation(:anomaly, :high, %{"message" => "disk usage at 95%"})
      assert {:ok, %Intent{} = intent} = Default.generate(obs)

      assert intent.kind == :maintenance
      assert intent.state == :proposed
      assert intent.source == %{type: :sprite, id: @sprite_id}
      assert intent.summary =~ "disk usage at 95%"
      assert intent.payload["trigger"] == "observation"
      assert intent.payload["observation_type"] == "anomaly"
      assert intent.payload["severity"] == "high"
      assert intent.metadata["observation_id"] == obs.id
      assert intent.metadata["generated_from"] == "observation"
    end

    test "critical severity anomaly generates a maintenance intent" do
      obs = build_observation(:anomaly, :critical, %{"message" => "service down"})
      assert {:ok, %Intent{} = intent} = Default.generate(obs)

      assert intent.kind == :maintenance
      assert intent.summary =~ "service down"
    end

    test "medium severity anomaly is skipped" do
      obs = build_observation(:anomaly, :medium)
      assert :skip = Default.generate(obs)
    end

    test "low severity anomaly is skipped" do
      obs = build_observation(:anomaly, :low)
      assert :skip = Default.generate(obs)
    end

    test "info severity anomaly is skipped" do
      obs = build_observation(:anomaly, :info)
      assert :skip = Default.generate(obs)
    end
  end

  # ── Default Generator: Recommendation Rules ──────────────────────

  describe "Default.generate/1 recommendation rules" do
    test "medium severity recommendation generates a maintenance intent" do
      obs =
        build_observation(:recommendation, :medium, %{"message" => "update base image"})

      assert {:ok, %Intent{} = intent} = Default.generate(obs)

      assert intent.kind == :maintenance
      assert intent.summary =~ "update base image"
      assert intent.metadata["observation_id"] == obs.id
    end

    test "high severity recommendation generates a maintenance intent" do
      obs = build_observation(:recommendation, :high, %{"description" => "pin dependency"})
      assert {:ok, %Intent{} = intent} = Default.generate(obs)

      assert intent.summary =~ "pin dependency"
    end

    test "critical severity recommendation generates a maintenance intent" do
      obs = build_observation(:recommendation, :critical)
      assert {:ok, %Intent{}} = Default.generate(obs)
    end

    test "low severity recommendation is skipped" do
      obs = build_observation(:recommendation, :low)
      assert :skip = Default.generate(obs)
    end

    test "info severity recommendation is skipped" do
      obs = build_observation(:recommendation, :info)
      assert :skip = Default.generate(obs)
    end
  end

  # ── Default Generator: Skip Rules ───────────────────────────────

  describe "Default.generate/1 skip rules" do
    test "metric observations are always skipped" do
      for severity <- Observation.valid_severities() do
        obs = build_observation(:metric, severity)
        assert :skip = Default.generate(obs)
      end
    end

    test "status observations are always skipped" do
      for severity <- Observation.valid_severities() do
        obs = build_observation(:status, severity)
        assert :skip = Default.generate(obs)
      end
    end
  end

  # ── Default Generator: Summary Extraction ───────────────────────

  describe "Default.generate/1 summary extraction" do
    test "uses message field from data" do
      obs = build_observation(:anomaly, :high, %{"message" => "specific message"})
      assert {:ok, intent} = Default.generate(obs)
      assert intent.summary =~ "specific message"
    end

    test "uses description field from data when no message" do
      obs = build_observation(:anomaly, :high, %{"description" => "detailed description"})
      assert {:ok, intent} = Default.generate(obs)
      assert intent.summary =~ "detailed description"
    end

    test "uses fallback when no message or description" do
      obs = build_observation(:anomaly, :high, %{"cpu" => 99})
      assert {:ok, intent} = Default.generate(obs)
      assert intent.summary =~ "observation requires attention"
    end
  end

  # ── Default Generator: Source Tagging ───────────────────────────

  describe "Default.generate/1 source tagging" do
    test "tags generated intents with sprite source" do
      obs = build_observation(:anomaly, :critical)
      assert {:ok, intent} = Default.generate(obs)

      assert intent.source == %{type: :sprite, id: @sprite_id}
    end

    test "includes observation_id in metadata" do
      obs = build_observation(:anomaly, :critical)
      assert {:ok, intent} = Default.generate(obs)

      assert intent.metadata["observation_id"] == obs.id
      assert intent.metadata["generated_from"] == "observation"
    end

    test "includes observation data in payload" do
      data = %{"metric" => "cpu", "value" => 99.5}
      obs = build_observation(:anomaly, :high, data)
      assert {:ok, intent} = Default.generate(obs)

      assert intent.payload["observation_data"] == data
    end
  end

  # ── IntentGenerator.generate/1 (dispatch) ──────────────────────

  describe "IntentGenerator.generate/1" do
    test "delegates to configured generator" do
      obs = build_observation(:anomaly, :critical)
      result = IntentGenerator.generate(obs)
      # Default generator should handle this
      assert {:ok, %Intent{}} = result
    end

    test "returns :skip for non-generating observations" do
      obs = build_observation(:metric, :info)
      assert :skip = IntentGenerator.generate(obs)
    end
  end
end
