defmodule Lattice.Intents.IntentTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Intents.Intent

  @valid_source %{type: :sprite, id: "sprite-001"}

  # ── new_action/2 ─────────────────────────────────────────────────────

  describe "new_action/2" do
    test "creates an action intent with valid params" do
      assert {:ok, intent} =
               Intent.new_action(@valid_source,
                 summary: "Deploy app",
                 payload: %{"target" => "prod"},
                 affected_resources: ["fly-app-1"],
                 expected_side_effects: ["app restarted"]
               )

      assert intent.kind == :action
      assert intent.state == :proposed
      assert intent.source == @valid_source
      assert intent.summary == "Deploy app"
      assert intent.payload == %{"target" => "prod"}
      assert intent.affected_resources == ["fly-app-1"]
      assert intent.expected_side_effects == ["app restarted"]
      assert String.starts_with?(intent.id, "int_")
      assert %DateTime{} = intent.inserted_at
      assert %DateTime{} = intent.updated_at
    end

    test "defaults optional fields" do
      assert {:ok, intent} =
               Intent.new_action(@valid_source,
                 summary: "Deploy",
                 payload: %{},
                 affected_resources: ["res"],
                 expected_side_effects: ["effect"]
               )

      assert intent.classification == nil
      assert intent.result == nil
      assert intent.metadata == %{}
      assert intent.rollback_strategy == nil
      assert intent.transition_log == []
      assert intent.classified_at == nil
      assert intent.approved_at == nil
      assert intent.started_at == nil
      assert intent.completed_at == nil
    end

    test "accepts optional metadata and rollback_strategy" do
      assert {:ok, intent} =
               Intent.new_action(@valid_source,
                 summary: "Deploy",
                 payload: %{},
                 affected_resources: ["res"],
                 expected_side_effects: ["effect"],
                 metadata: %{"priority" => "high"},
                 rollback_strategy: "redeploy previous version"
               )

      assert intent.metadata == %{"priority" => "high"}
      assert intent.rollback_strategy == "redeploy previous version"
    end

    test "rejects missing summary" do
      assert {:error, {:missing_field, :summary}} =
               Intent.new_action(@valid_source,
                 payload: %{},
                 affected_resources: ["res"],
                 expected_side_effects: ["effect"]
               )
    end

    test "rejects missing payload" do
      assert {:error, {:missing_field, :payload}} =
               Intent.new_action(@valid_source,
                 summary: "Deploy",
                 affected_resources: ["res"],
                 expected_side_effects: ["effect"]
               )
    end

    test "rejects missing affected_resources" do
      assert {:error, {:missing_field, :affected_resources}} =
               Intent.new_action(@valid_source,
                 summary: "Deploy",
                 payload: %{},
                 expected_side_effects: ["effect"]
               )
    end

    test "rejects empty affected_resources list" do
      assert {:error, {:missing_field, :affected_resources}} =
               Intent.new_action(@valid_source,
                 summary: "Deploy",
                 payload: %{},
                 affected_resources: [],
                 expected_side_effects: ["effect"]
               )
    end

    test "rejects missing expected_side_effects" do
      assert {:error, {:missing_field, :expected_side_effects}} =
               Intent.new_action(@valid_source,
                 summary: "Deploy",
                 payload: %{},
                 affected_resources: ["res"]
               )
    end

    test "rejects empty expected_side_effects list" do
      assert {:error, {:missing_field, :expected_side_effects}} =
               Intent.new_action(@valid_source,
                 summary: "Deploy",
                 payload: %{},
                 affected_resources: ["res"],
                 expected_side_effects: []
               )
    end
  end

  # ── new_inquiry/2 ────────────────────────────────────────────────────

  describe "new_inquiry/2" do
    @valid_inquiry_payload %{
      "what_requested" => "API key for service X",
      "why_needed" => "Required for integration",
      "scope_of_impact" => "single service",
      "expiration" => "2026-03-01"
    }

    test "creates an inquiry intent with valid params" do
      assert {:ok, intent} =
               Intent.new_inquiry(@valid_source,
                 summary: "Need API key",
                 payload: @valid_inquiry_payload
               )

      assert intent.kind == :inquiry
      assert intent.state == :proposed
      assert intent.summary == "Need API key"
      assert intent.payload == @valid_inquiry_payload
    end

    test "rejects missing what_requested in payload" do
      payload = Map.delete(@valid_inquiry_payload, "what_requested")

      assert {:error, {:missing_payload_field, "what_requested"}} =
               Intent.new_inquiry(@valid_source, summary: "Need key", payload: payload)
    end

    test "rejects missing why_needed in payload" do
      payload = Map.delete(@valid_inquiry_payload, "why_needed")

      assert {:error, {:missing_payload_field, "why_needed"}} =
               Intent.new_inquiry(@valid_source, summary: "Need key", payload: payload)
    end

    test "rejects missing scope_of_impact in payload" do
      payload = Map.delete(@valid_inquiry_payload, "scope_of_impact")

      assert {:error, {:missing_payload_field, "scope_of_impact"}} =
               Intent.new_inquiry(@valid_source, summary: "Need key", payload: payload)
    end

    test "rejects missing expiration in payload" do
      payload = Map.delete(@valid_inquiry_payload, "expiration")

      assert {:error, {:missing_payload_field, "expiration"}} =
               Intent.new_inquiry(@valid_source, summary: "Need key", payload: payload)
    end

    test "rejects missing summary" do
      assert {:error, {:missing_field, :summary}} =
               Intent.new_inquiry(@valid_source, payload: @valid_inquiry_payload)
    end

    test "rejects missing payload" do
      assert {:error, {:missing_field, :payload}} =
               Intent.new_inquiry(@valid_source, summary: "Need key")
    end

    test "does not require affected_resources or expected_side_effects" do
      assert {:ok, intent} =
               Intent.new_inquiry(@valid_source,
                 summary: "Need key",
                 payload: @valid_inquiry_payload
               )

      assert intent.affected_resources == []
      assert intent.expected_side_effects == []
    end
  end

  # ── new_maintenance/2 ────────────────────────────────────────────────

  describe "new_maintenance/2" do
    test "creates a maintenance intent with valid params" do
      assert {:ok, intent} =
               Intent.new_maintenance(@valid_source,
                 summary: "Update base image",
                 payload: %{"image" => "elixir:1.18"}
               )

      assert intent.kind == :maintenance
      assert intent.state == :proposed
      assert intent.summary == "Update base image"
    end

    test "rejects missing summary" do
      assert {:error, {:missing_field, :summary}} =
               Intent.new_maintenance(@valid_source, payload: %{})
    end

    test "rejects missing payload" do
      assert {:error, {:missing_field, :payload}} =
               Intent.new_maintenance(@valid_source, summary: "Update")
    end

    test "does not require affected_resources or expected_side_effects" do
      assert {:ok, intent} =
               Intent.new_maintenance(@valid_source,
                 summary: "Update",
                 payload: %{}
               )

      assert intent.affected_resources == []
      assert intent.expected_side_effects == []
    end
  end

  # ── Source Validation ────────────────────────────────────────────────

  describe "source validation" do
    test "accepts all valid source types" do
      for type <- Intent.valid_source_types() do
        source = %{type: type, id: "test-id"}

        assert {:ok, %Intent{source: ^source}} =
                 Intent.new_maintenance(source, summary: "Test", payload: %{})
      end
    end

    test "rejects invalid source type" do
      source = %{type: :unknown, id: "test-id"}

      assert {:error, {:invalid_source_type, :unknown}} =
               Intent.new_maintenance(source, summary: "Test", payload: %{})
    end
  end

  # ── ID Generation ───────────────────────────────────────────────────

  describe "id generation" do
    test "generates unique IDs with int_ prefix" do
      {:ok, a} = Intent.new_maintenance(@valid_source, summary: "A", payload: %{})
      {:ok, b} = Intent.new_maintenance(@valid_source, summary: "B", payload: %{})

      assert String.starts_with?(a.id, "int_")
      assert String.starts_with?(b.id, "int_")
      assert a.id != b.id
    end
  end

  # ── Public Helpers ──────────────────────────────────────────────────

  describe "valid_kinds/0" do
    test "returns all three kinds" do
      assert Intent.valid_kinds() == [:action, :inquiry, :maintenance]
    end
  end

  describe "valid_source_types/0" do
    test "returns all valid source types" do
      types = Intent.valid_source_types()
      assert :sprite in types
      assert :agent in types
      assert :cron in types
      assert :operator in types
      assert length(types) == 4
    end
  end

  # ── Struct ──────────────────────────────────────────────────────────

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Intent, %{kind: :action})
      end
    end
  end
end
