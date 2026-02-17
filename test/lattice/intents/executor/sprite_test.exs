defmodule Lattice.Intents.Executor.SpriteTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Executor.Sprite
  alias Lattice.Intents.Intent

  setup :verify_on_exit!

  # ── Helpers ──────────────────────────────────────────────────────────

  defp sprite_action_intent(capability \\ "sprites", operation \\ "list_sprites", args \\ []) do
    {:ok, intent} =
      Intent.new_action(
        %{type: :sprite, id: "sprite-001"},
        summary: "Test action",
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

  defp operator_action_intent do
    {:ok, intent} =
      Intent.new_action(
        %{type: :operator, id: "op-001"},
        summary: "Operator action",
        payload: %{"capability" => "sprites", "operation" => "list_sprites"},
        affected_resources: ["sprites"],
        expected_side_effects: ["none"]
      )

    intent
  end

  defp intent_without_capability do
    {:ok, intent} =
      Intent.new_action(
        %{type: :sprite, id: "sprite-001"},
        summary: "No capability",
        payload: %{"data" => "value"},
        affected_resources: ["something"],
        expected_side_effects: ["effect"]
      )

    intent
  end

  # ── can_execute?/1 ──────────────────────────────────────────────────

  describe "can_execute?/1" do
    test "returns true for sprite-sourced action with capability and operation" do
      intent = sprite_action_intent()

      assert Sprite.can_execute?(intent) == true
    end

    test "returns false for operator-sourced action" do
      intent = operator_action_intent()

      assert Sprite.can_execute?(intent) == false
    end

    test "returns false when payload lacks capability" do
      intent = intent_without_capability()

      assert Sprite.can_execute?(intent) == false
    end

    test "returns false for maintenance intents" do
      {:ok, intent} =
        Intent.new_maintenance(
          %{type: :sprite, id: "sprite-001"},
          summary: "Update image",
          payload: %{"capability" => "fly", "operation" => "deploy"}
        )

      assert Sprite.can_execute?(intent) == false
    end
  end

  # ── execute/1 ──────────────────────────────────────────────────────

  describe "execute/1" do
    test "successful execution returns success result" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, [%{id: "sprite-001"}]} end)

      intent = sprite_action_intent("sprites", "list_sprites")

      assert {:ok, %ExecutionResult{status: :success} = result} = Sprite.execute(intent)
      assert result.output == [%{id: "sprite-001"}]
      assert result.duration_ms >= 0
      assert %DateTime{} = result.started_at
      assert %DateTime{} = result.completed_at
      assert result.executor == Lattice.Intents.Executor.Sprite
    end

    test "capability returning error yields failure result" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:error, :api_timeout} end)

      intent = sprite_action_intent("sprites", "list_sprites")

      # The capability returned {:error, :api_timeout} which the executor
      # recognizes as a failure (tagged tuple convention)
      assert {:ok, %ExecutionResult{status: :failure} = result} = Sprite.execute(intent)
      assert result.error == :api_timeout
    end

    test "unknown capability returns error" do
      intent = sprite_action_intent("nonexistent", "some_op")

      assert {:ok, %ExecutionResult{status: :failure} = result} = Sprite.execute(intent)
      assert result.error == {:unknown_capability, "nonexistent"}
    end

    test "unconfigured capability returns error" do
      previous = Application.get_env(:lattice, :capabilities)
      Application.put_env(:lattice, :capabilities, Keyword.delete(previous, :sprites))

      try do
        intent = sprite_action_intent("sprites", "list_sprites")
        assert {:ok, %ExecutionResult{status: :failure} = result} = Sprite.execute(intent)
        assert result.error == {:capability_not_configured, :sprites}
      after
        Application.put_env(:lattice, :capabilities, previous)
      end
    end

    test "passes args to capability function" do
      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "sprite-001" -> {:ok, %{id: "sprite-001", status: "running"}} end)

      intent = sprite_action_intent("sprites", "get_sprite", ["sprite-001"])

      assert {:ok, %ExecutionResult{status: :success} = result} = Sprite.execute(intent)
      assert result.output == %{id: "sprite-001", status: "running"}
    end

    test "tracks execution timing" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn ->
        Process.sleep(10)
        {:ok, []}
      end)

      intent = sprite_action_intent("sprites", "list_sprites")

      assert {:ok, %ExecutionResult{} = result} = Sprite.execute(intent)
      assert result.duration_ms >= 10
      assert DateTime.compare(result.completed_at, result.started_at) in [:gt, :eq]
    end
  end
end
