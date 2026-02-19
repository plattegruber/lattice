defmodule Lattice.Docs.DriftDetectorTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Docs.DriftDetector
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS
  alias Lattice.Policy.RepoProfile

  setup do
    StoreETS.reset()
    DriftDetector.clear()
    :ok
  end

  describe "check_intent/1" do
    test "detects API mutation drift" do
      {:ok, intent} =
        Intent.new_action(%{type: :sprite, id: "s1"},
          summary: "Create new sprite endpoint",
          payload: %{
            "capability" => "sprites",
            "operation" => "create_sprite",
            "repo" => "plattegruber/lattice"
          },
          affected_resources: ["sprites"],
          expected_side_effects: ["api_change"]
        )

      # Simulate completed state
      intent = %{intent | state: :completed}

      drift = DriftDetector.check_intent(intent)
      assert drift != nil
      assert drift.change_type == :api_endpoint
      assert drift.repo == "plattegruber/lattice"
      assert is_binary(drift.reason)
    end

    test "returns nil for non-mutation operations" do
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
      assert DriftDetector.check_intent(intent) == nil
    end

    test "returns nil for intents without a repo" do
      {:ok, intent} =
        Intent.new_action(%{type: :sprite, id: "s1"},
          summary: "Do something",
          payload: %{"capability" => "sprites", "operation" => "create_sprite"},
          affected_resources: ["sprites"],
          expected_side_effects: ["none"]
        )

      intent = %{intent | state: :completed}
      assert DriftDetector.check_intent(intent) == nil
    end

    test "detects maintenance/config drift" do
      {:ok, intent} =
        Intent.new_action(%{type: :system, id: "sys"},
          summary: "Update configuration",
          payload: %{"repo" => "plattegruber/lattice"},
          affected_resources: ["config"],
          expected_side_effects: ["config_change"]
        )

      intent = %{intent | kind: :maintenance, state: :completed}
      drift = DriftDetector.check_intent(intent)
      assert drift != nil
      assert drift.change_type == :config
    end

    test "uses repo profile doc_paths when available" do
      RepoProfile.put(%RepoProfile{
        repo: "plattegruber/lattice",
        doc_paths: ["docs/api.md", "docs/guides/"]
      })

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
      drift = DriftDetector.check_intent(intent)
      assert drift != nil
      assert "docs/api.md" in drift.affected_docs
      assert "docs/guides/" in drift.affected_docs
    end
  end

  describe "drift_log/0" do
    test "accumulates drift entries from PubSub" do
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

      # Directly store the intent and walk through states
      {:ok, stored} = StoreETS.create(intent)
      {:ok, _} = Store.update(stored.id, %{state: :classified})
      {:ok, _} = Store.update(stored.id, %{state: :awaiting_approval})
      {:ok, _} = Store.update(stored.id, %{state: :approved})
      {:ok, _} = Store.update(stored.id, %{state: :running})
      {:ok, _} = Store.update(stored.id, %{state: :completed})

      # Give PubSub time
      Process.sleep(50)

      log = DriftDetector.drift_log()
      assert length(log) == 1
      assert hd(log).change_type == :api_endpoint
    end
  end

  describe "clear/0" do
    test "clears the drift log" do
      # Manually check an intent to populate
      {:ok, intent} =
        Intent.new_action(%{type: :sprite, id: "s1"},
          summary: "Create",
          payload: %{
            "capability" => "sprites",
            "operation" => "create_sprite",
            "repo" => "plattegruber/lattice"
          },
          affected_resources: ["sprites"],
          expected_side_effects: ["api_change"]
        )

      intent = %{intent | state: :completed}
      assert DriftDetector.check_intent(intent) != nil

      DriftDetector.clear()
      assert DriftDetector.drift_log() == []
    end
  end
end
