defmodule Lattice.Health.RemediatorTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Health.Detector
  alias Lattice.Health.Remediator
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Observation
  alias Lattice.Intents.Store
  alias Lattice.Events

  setup do
    Detector.clear_history()
    Remediator.clear_history()
    :ok
  end

  describe "remediation proposal" do
    test "proposes remediation when health_detect intent is approved" do
      # Create and broadcast a critical observation.
      # The Detector will create a health_detect intent and auto-approve it.
      # The Remediator should then propose a health_remediate intent.
      {:ok, obs} =
        Observation.new("sprite-rem-test", :anomaly,
          severity: :critical,
          data: %{"message" => "CPU overload", "category" => "rem_test_proposal"}
        )

      Events.broadcast_observation(obs)
      Process.sleep(200)

      {:ok, intents} = Store.list()
      remediate_intents = Enum.filter(intents, &(&1.kind == :health_remediate))
      assert length(remediate_intents) >= 1

      remediate = List.last(remediate_intents)
      assert remediate.payload["remediation_type"] == "auto_fix"
      assert remediate.payload["original_summary"] =~ "CPU overload"
      assert is_binary(remediate.payload["detect_intent_id"])
    end

    test "links remediate intent to originating detect intent" do
      {:ok, obs} =
        Observation.new("sprite-rem-link", :anomaly,
          severity: :critical,
          data: %{"message" => "Disk full", "category" => "rem_test_link"}
        )

      Events.broadcast_observation(obs)
      Process.sleep(200)

      {:ok, intents} = Store.list()

      detect =
        intents
        |> Enum.filter(fn i ->
          i.kind == :health_detect and i.payload["sprite_id"] == "sprite-rem-link"
        end)
        |> List.last()

      remediate =
        intents
        |> Enum.filter(fn i ->
          i.kind == :health_remediate and
            i.payload["detect_intent_id"] == detect.id
        end)
        |> List.last()

      assert remediate != nil
      assert remediate.payload["detect_intent_id"] == detect.id
    end

    test "does not propose remediation for non-health_detect intents" do
      # Create a regular action intent and approve it manually
      source = %{type: :operator, id: "test"}

      {:ok, intent} =
        Intent.new_action(source,
          summary: "test action",
          payload: %{"capability" => "sprites", "operation" => "list"},
          affected_resources: ["fleet"],
          expected_side_effects: ["list sprites"]
        )

      {:ok, _} = Store.create(intent)
      Store.update(intent.id, %{state: :classified, classification: :safe})
      Store.update(intent.id, %{state: :approved, actor: "test"})

      Process.sleep(100)

      history = Remediator.history()
      relevant = Enum.filter(history, &(&1.detect_intent_id == intent.id))
      assert relevant == []
    end
  end

  describe "auto-remediation" do
    test "auto-approves remediation for critical severity" do
      {:ok, obs} =
        Observation.new("sprite-rem-auto", :anomaly,
          severity: :critical,
          data: %{"message" => "Critical failure", "category" => "rem_test_auto"}
        )

      Events.broadcast_observation(obs)
      Process.sleep(200)

      {:ok, intents} = Store.list()

      remediate =
        intents
        |> Enum.filter(fn i ->
          i.kind == :health_remediate and
            i.payload["severity"] == "critical"
        end)
        |> List.last()

      assert remediate != nil
      assert remediate.state == :approved
    end

    test "does not auto-approve remediation for high severity" do
      {:ok, obs} =
        Observation.new("sprite-rem-high", :anomaly,
          severity: :high,
          data: %{"message" => "High severity issue", "category" => "rem_test_high"}
        )

      Events.broadcast_observation(obs)
      Process.sleep(200)

      {:ok, intents} = Store.list()

      # High severity creates a health_detect intent that is NOT auto-approved
      # (it stays at :proposed), so the Remediator won't fire
      detect =
        intents
        |> Enum.filter(fn i ->
          i.kind == :health_detect and i.payload["sprite_id"] == "sprite-rem-high"
        end)
        |> List.last()

      # High severity detect intents are proposed, not approved
      assert detect.state == :proposed

      # No remediate intents should be created
      remediate =
        intents
        |> Enum.filter(fn i ->
          i.kind == :health_remediate and
            i.payload["detect_intent_id"] == detect.id
        end)

      assert remediate == []
    end
  end

  describe "history/0" do
    test "tracks remediation proposals" do
      {:ok, obs} =
        Observation.new("sprite-rem-hist", :anomaly,
          severity: :critical,
          data: %{"message" => "Track this", "category" => "rem_test_hist"}
        )

      Events.broadcast_observation(obs)
      Process.sleep(200)

      history = Remediator.history()
      assert length(history) >= 1

      entry = List.first(history)
      assert is_binary(entry.detect_intent_id)
      assert is_binary(entry.remediate_intent_id)
      assert entry.severity == :critical
      assert entry.auto_approved == true
    end

    test "clear_history/0 resets history" do
      {:ok, obs} =
        Observation.new("sprite-rem-clear", :anomaly,
          severity: :critical,
          data: %{"message" => "Clear me", "category" => "rem_test_clear"}
        )

      Events.broadcast_observation(obs)
      Process.sleep(200)

      Remediator.clear_history()
      assert Remediator.history() == []
    end
  end
end
