defmodule Lattice.Capabilities.Sprites.StubTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.Sprites.Stub

  describe "create_sprite/2" do
    test "returns a new sprite with the given name" do
      assert {:ok, sprite} = Stub.create_sprite("test-sprite")
      assert sprite.id == "test-sprite"
      assert sprite.name == "test-sprite"
      assert sprite.status == "running"
      assert sprite.started_at != nil
    end

    test "returns a sprite with required fields" do
      {:ok, sprite} = Stub.create_sprite("my-sprite")

      assert Map.has_key?(sprite, :id)
      assert Map.has_key?(sprite, :name)
      assert Map.has_key?(sprite, :status)
    end
  end

  describe "list_sprites/0" do
    test "returns a list of sprites" do
      assert {:ok, [_ | _]} = Stub.list_sprites()
    end

    test "each sprite has required fields" do
      {:ok, sprites} = Stub.list_sprites()

      for sprite <- sprites do
        assert Map.has_key?(sprite, :id)
        assert Map.has_key?(sprite, :name)
        assert Map.has_key?(sprite, :status)
      end
    end
  end

  describe "get_sprite/1" do
    test "returns a sprite for a known ID" do
      assert {:ok, sprite} = Stub.get_sprite("sprite-001")
      assert sprite.id == "sprite-001"
      assert sprite.name == "atlas"
    end

    test "returns error for an unknown ID" do
      assert {:error, :not_found} = Stub.get_sprite("nonexistent")
    end
  end

  describe "wake/1" do
    test "returns a running sprite for a known ID" do
      assert {:ok, sprite} = Stub.wake("sprite-002")
      assert sprite.status == "running"
      assert sprite.started_at != nil
    end

    test "returns error for an unknown ID" do
      assert {:error, :not_found} = Stub.wake("nonexistent")
    end
  end

  describe "sleep/1" do
    test "returns a sleeping sprite for a known ID" do
      assert {:ok, sprite} = Stub.sleep("sprite-001")
      assert sprite.status == "sleeping"
      assert sprite.task == nil
      assert sprite.started_at == nil
    end

    test "returns error for an unknown ID" do
      assert {:error, :not_found} = Stub.sleep("nonexistent")
    end
  end

  describe "exec/2" do
    test "returns command output for a known sprite" do
      assert {:ok, result} = Stub.exec("sprite-001", "echo hello")
      assert result.sprite_id == "sprite-001"
      assert result.command == "echo hello"
      assert is_binary(result.output)
      assert result.exit_code == 0
    end

    test "returns error for an unknown sprite" do
      assert {:error, :not_found} = Stub.exec("nonexistent", "echo hello")
    end
  end

  describe "fetch_logs/2" do
    test "returns log lines for a known sprite" do
      assert {:ok, [first | _rest]} = Stub.fetch_logs("sprite-001", [])
      assert is_binary(first)
    end

    test "returns error for an unknown sprite" do
      assert {:error, :not_found} = Stub.fetch_logs("nonexistent", [])
    end
  end
end
