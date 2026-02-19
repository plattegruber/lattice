defmodule Lattice.Policy.SpritePurposeTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Policy.SpritePurpose

  setup do
    {:ok, purposes} = SpritePurpose.list()

    for p <- purposes, String.starts_with?(p.sprite_name || "", "test-") do
      SpritePurpose.delete(p.sprite_name)
    end

    :ok
  end

  describe "put/1 and get/1" do
    test "stores and retrieves a purpose" do
      purpose = %SpritePurpose{
        sprite_name: "test-sprite-1",
        repo: "org/my-repo",
        task_kinds: ["open_pr", "fixup"],
        labels: ["frontend"],
        notes: "Handles frontend PRs"
      }

      assert :ok = SpritePurpose.put(purpose)
      assert {:ok, retrieved} = SpritePurpose.get("test-sprite-1")
      assert retrieved.sprite_name == "test-sprite-1"
      assert retrieved.repo == "org/my-repo"
      assert retrieved.task_kinds == ["open_pr", "fixup"]
      assert retrieved.labels == ["frontend"]
      assert retrieved.notes == "Handles frontend PRs"
    after
      SpritePurpose.delete("test-sprite-1")
    end

    test "returns error for missing sprite" do
      assert {:error, :not_found} = SpritePurpose.get("test-nonexistent")
    end
  end

  describe "list/0" do
    test "lists all purposes" do
      SpritePurpose.put(%SpritePurpose{sprite_name: "test-a", repo: "org/a"})
      SpritePurpose.put(%SpritePurpose{sprite_name: "test-b", repo: "org/b"})

      {:ok, purposes} = SpritePurpose.list()
      names = Enum.map(purposes, & &1.sprite_name)
      assert "test-a" in names
      assert "test-b" in names
    after
      SpritePurpose.delete("test-a")
      SpritePurpose.delete("test-b")
    end
  end

  describe "delete/1" do
    test "removes a purpose" do
      SpritePurpose.put(%SpritePurpose{sprite_name: "test-del"})
      assert {:ok, _} = SpritePurpose.get("test-del")

      SpritePurpose.delete("test-del")
      assert {:error, :not_found} = SpritePurpose.get("test-del")
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips through map" do
      purpose = %SpritePurpose{
        sprite_name: "test-rt",
        repo: "org/repo",
        task_kinds: ["build"],
        labels: ["ci"],
        notes: "CI sprite"
      }

      map = SpritePurpose.to_map(purpose)
      restored = SpritePurpose.from_map(map)

      assert restored.sprite_name == purpose.sprite_name
      assert restored.repo == purpose.repo
      assert restored.task_kinds == purpose.task_kinds
    end
  end
end
