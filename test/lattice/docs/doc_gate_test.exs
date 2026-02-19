defmodule Lattice.Docs.DocGateTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Docs.DocGate
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store.ETS, as: StoreETS
  alias Lattice.Policy.RepoProfile

  setup do
    StoreETS.reset()
    :ok
  end

  describe "check/1" do
    test "returns :ok for intents that don't need docs" do
      {:ok, intent} =
        Intent.new_action(%{type: :sprite, id: "s1"},
          summary: "List sprites",
          payload: %{
            "capability" => "sprites",
            "operation" => "list_sprites",
            "repo" => "plattegruber/lattice"
          },
          affected_resources: ["sprites"],
          expected_side_effects: ["none"]
        )

      intent = %{intent | state: :completed}
      assert DocGate.check(intent) == :ok
    end

    test "returns {:needs_docs, drift} for API mutations" do
      {:ok, intent} =
        Intent.new_action(%{type: :sprite, id: "s1"},
          summary: "Create endpoint",
          payload: %{
            "capability" => "sprites",
            "operation" => "create_sprite",
            "repo" => "plattegruber/lattice"
          },
          affected_resources: ["sprites"],
          expected_side_effects: ["api_change"]
        )

      intent = %{intent | state: :completed}
      assert {:needs_docs, drift} = DocGate.check(intent)
      assert drift.change_type == :api_endpoint
    end
  end

  describe "propose_doc_update/1" do
    test "creates a doc_update intent" do
      drift = %{
        intent_id: "int-123",
        repo: "plattegruber/lattice",
        change_type: :api_endpoint,
        reason: "API endpoint change may require docs update",
        affected_docs: ["API documentation"],
        detected_at: DateTime.utc_now()
      }

      assert {:ok, proposed} = DocGate.propose_doc_update(drift)
      assert proposed.kind == :doc_update
      assert proposed.payload["repo"] == "plattegruber/lattice"
      assert proposed.payload["source_intent_id"] == "int-123"
    end
  end

  describe "check_freshness/1" do
    test "returns freshness map for default files" do
      result = DocGate.check_freshness("plattegruber/lattice")
      assert is_map(result)
      assert Map.has_key?(result, "CLAUDE.md")
      assert Map.has_key?(result, "README.md")
    end

    test "includes repo profile doc_paths" do
      RepoProfile.put(%RepoProfile{
        repo: "plattegruber/lattice",
        doc_paths: ["docs/api.md"]
      })

      result = DocGate.check_freshness("plattegruber/lattice")
      assert Map.has_key?(result, "docs/api.md")
    end
  end
end
