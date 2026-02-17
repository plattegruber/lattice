defmodule Lattice.Intents.Executor.ControlPlaneTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Executor.ControlPlane
  alias Lattice.Intents.Intent

  setup :verify_on_exit!

  # ── Helpers ──────────────────────────────────────────────────────────

  defp operator_action_intent(capability \\ "sprites", operation \\ "list_sprites", args \\ []) do
    {:ok, intent} =
      Intent.new_action(
        %{type: :operator, id: "op-001"},
        summary: "Operator action",
        payload: %{
          "capability" => capability,
          "operation" => operation,
          "args" => args
        },
        affected_resources: ["sprites"],
        expected_side_effects: ["none"]
      )

    intent
  end

  defp cron_action_intent do
    {:ok, intent} =
      Intent.new_action(
        %{type: :cron, id: "cron-001"},
        summary: "Scheduled action",
        payload: %{
          "capability" => "sprites",
          "operation" => "list_sprites",
          "args" => []
        },
        affected_resources: ["sprites"],
        expected_side_effects: ["none"]
      )

    intent
  end

  defp maintenance_intent do
    {:ok, intent} =
      Intent.new_maintenance(
        %{type: :sprite, id: "sprite-001"},
        summary: "Update base image",
        payload: %{
          "capability" => "fly",
          "operation" => "machine_status",
          "args" => ["machine-1"]
        }
      )

    intent
  end

  defp sprite_action_intent do
    {:ok, intent} =
      Intent.new_action(
        %{type: :sprite, id: "sprite-001"},
        summary: "Sprite action",
        payload: %{"capability" => "sprites", "operation" => "list_sprites"},
        affected_resources: ["sprites"],
        expected_side_effects: ["none"]
      )

    intent
  end

  # ── can_execute?/1 ──────────────────────────────────────────────────

  describe "can_execute?/1" do
    test "returns true for operator-sourced action with capability" do
      intent = operator_action_intent()

      assert ControlPlane.can_execute?(intent) == true
    end

    test "returns true for cron-sourced action with capability" do
      intent = cron_action_intent()

      assert ControlPlane.can_execute?(intent) == true
    end

    test "returns true for maintenance intent with capability" do
      intent = maintenance_intent()

      assert ControlPlane.can_execute?(intent) == true
    end

    test "returns false for sprite-sourced action" do
      intent = sprite_action_intent()

      assert ControlPlane.can_execute?(intent) == false
    end

    test "returns false for inquiry intents" do
      {:ok, intent} =
        Intent.new_inquiry(
          %{type: :operator, id: "op-001"},
          summary: "Need key",
          payload: %{
            "what_requested" => "API key",
            "why_needed" => "Integration",
            "scope_of_impact" => "single service",
            "expiration" => "2026-03-01"
          }
        )

      assert ControlPlane.can_execute?(intent) == false
    end
  end

  # ── execute/1 ──────────────────────────────────────────────────────

  describe "execute/1" do
    test "successful execution returns success result" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, [%{id: "s1"}, %{id: "s2"}]} end)

      intent = operator_action_intent("sprites", "list_sprites")

      assert {:ok, %ExecutionResult{status: :success} = result} = ControlPlane.execute(intent)
      assert result.output == [%{id: "s1"}, %{id: "s2"}]
      assert result.duration_ms >= 0
      assert result.executor == Lattice.Intents.Executor.ControlPlane
    end

    test "capability error yields failure result" do
      intent = operator_action_intent("nonexistent", "op")

      assert {:ok, %ExecutionResult{status: :failure} = result} = ControlPlane.execute(intent)
      assert result.error == {:unknown_capability, "nonexistent"}
    end

    test "passes args to capability function" do
      Lattice.Capabilities.MockFly
      |> expect(:machine_status, fn "machine-1" -> {:ok, %{state: "running"}} end)

      intent = operator_action_intent("fly", "machine_status", ["machine-1"])

      assert {:ok, %ExecutionResult{status: :success} = result} = ControlPlane.execute(intent)
      assert result.output == %{state: "running"}
    end

    test "tracks execution timing" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn ->
        Process.sleep(10)
        {:ok, []}
      end)

      intent = operator_action_intent("sprites", "list_sprites")

      assert {:ok, %ExecutionResult{} = result} = ControlPlane.execute(intent)
      assert result.duration_ms >= 10
    end
  end
end
