defmodule Lattice.Intents.Executor.RouterTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Executor.ControlPlane
  alias Lattice.Intents.Executor.Router
  alias Lattice.Intents.Executor.Sprite
  alias Lattice.Intents.Intent

  # ── Helpers ──────────────────────────────────────────────────────────

  defp action_intent_from_sprite do
    {:ok, intent} =
      Intent.new_action(
        %{type: :sprite, id: "sprite-001"},
        summary: "List all sprites",
        payload: %{"capability" => "sprites", "operation" => "list_sprites"},
        affected_resources: ["sprites"],
        expected_side_effects: ["none"]
      )

    intent
  end

  defp action_intent_from_operator do
    {:ok, intent} =
      Intent.new_action(
        %{type: :operator, id: "op-001"},
        summary: "Deploy app",
        payload: %{"capability" => "fly", "operation" => "deploy"},
        affected_resources: ["fly-app"],
        expected_side_effects: ["app restarted"]
      )

    intent
  end

  defp action_intent_from_cron do
    {:ok, intent} =
      Intent.new_action(
        %{type: :cron, id: "cron-001"},
        summary: "Scheduled deploy",
        payload: %{"capability" => "fly", "operation" => "deploy"},
        affected_resources: ["fly-app"],
        expected_side_effects: ["app restarted"]
      )

    intent
  end

  defp maintenance_intent do
    {:ok, intent} =
      Intent.new_maintenance(
        %{type: :sprite, id: "sprite-001"},
        summary: "Update base image",
        payload: %{"capability" => "fly", "operation" => "deploy"}
      )

    intent
  end

  defp inquiry_intent do
    {:ok, intent} =
      Intent.new_inquiry(
        %{type: :operator, id: "op-001"},
        summary: "Need API key",
        payload: %{
          "what_requested" => "API key",
          "why_needed" => "Integration",
          "scope_of_impact" => "single service",
          "expiration" => "2026-03-01"
        }
      )

    intent
  end

  defp action_intent_without_capability do
    {:ok, intent} =
      Intent.new_action(
        %{type: :sprite, id: "sprite-001"},
        summary: "Do something",
        payload: %{"data" => "value"},
        affected_resources: ["something"],
        expected_side_effects: ["effect"]
      )

    intent
  end

  # ── route/1 ─────────────────────────────────────────────────────────

  describe "route/1" do
    test "routes sprite-sourced action to Sprite executor" do
      intent = action_intent_from_sprite()

      assert {:ok, Sprite} = Router.route(intent)
    end

    test "routes operator-sourced action to ControlPlane executor" do
      intent = action_intent_from_operator()

      assert {:ok, ControlPlane} = Router.route(intent)
    end

    test "routes cron-sourced action to ControlPlane executor" do
      intent = action_intent_from_cron()

      assert {:ok, ControlPlane} = Router.route(intent)
    end

    test "routes maintenance intent to ControlPlane executor" do
      intent = maintenance_intent()

      assert {:ok, ControlPlane} = Router.route(intent)
    end

    test "returns no_executor for inquiry intents" do
      intent = inquiry_intent()

      assert {:error, :no_executor} = Router.route(intent)
    end

    test "returns no_executor when intent lacks capability/operation" do
      intent = action_intent_without_capability()

      assert {:error, :no_executor} = Router.route(intent)
    end
  end

  describe "executors/0" do
    test "returns the registered executor modules" do
      executors = Router.executors()

      assert Sprite in executors
      assert ControlPlane in executors
    end
  end
end
