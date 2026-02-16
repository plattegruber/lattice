defmodule Lattice.Safety.ActionTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Safety.Action

  describe "new/3" do
    test "creates an action with :safe classification" do
      assert {:ok, action} = Action.new(:sprites, :list_sprites, :safe)

      assert action.capability == :sprites
      assert action.operation == :list_sprites
      assert action.classification == :safe
    end

    test "creates an action with :controlled classification" do
      assert {:ok, action} = Action.new(:sprites, :wake, :controlled)

      assert action.capability == :sprites
      assert action.operation == :wake
      assert action.classification == :controlled
    end

    test "creates an action with :dangerous classification" do
      assert {:ok, action} = Action.new(:fly, :deploy, :dangerous)

      assert action.capability == :fly
      assert action.operation == :deploy
      assert action.classification == :dangerous
    end

    test "rejects invalid classification" do
      assert {:error, {:invalid_classification, :unknown}} =
               Action.new(:sprites, :list_sprites, :unknown)
    end
  end

  describe "valid_classifications/0" do
    test "returns all three classification levels" do
      assert Action.valid_classifications() == [:safe, :controlled, :dangerous]
    end
  end

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Action, %{capability: :sprites})
      end
    end
  end
end
