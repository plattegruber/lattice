defmodule Lattice.Capabilities.Sprites.LiveIntegrationTest do
  @moduledoc """
  Integration tests for the live Sprites API client.

  These tests hit the real Sprites API and require a valid SPRITES_API_TOKEN
  environment variable. Run with:

      SPRITES_API_TOKEN=your-token mix test --only integration
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Lattice.Capabilities.Sprites.Live

  setup do
    unless System.get_env("SPRITES_API_TOKEN") do
      raise "SPRITES_API_TOKEN must be set for integration tests"
    end

    :ok
  end

  describe "list_sprites/0" do
    test "returns {:ok, list} from the live API" do
      assert {:ok, sprites} = Live.list_sprites()
      assert is_list(sprites)

      for sprite <- sprites do
        assert Map.has_key?(sprite, :id)
        assert Map.has_key?(sprite, :name)
        assert Map.has_key?(sprite, :status)
        assert sprite.status in [:hibernating, :waking, :ready, :busy, :error]
      end
    end
  end

  describe "get_sprite/1" do
    test "returns {:ok, sprite} for a known sprite" do
      {:ok, sprites} = Live.list_sprites()

      case sprites do
        [first | _] ->
          assert {:ok, sprite} = Live.get_sprite(first.name)
          assert sprite.name == first.name
          assert sprite.status in [:hibernating, :waking, :ready, :busy, :error]

        [] ->
          # No sprites available — skip gracefully
          :ok
      end
    end

    test "returns {:error, :not_found} for an unknown sprite" do
      assert {:error, :not_found} =
               Live.get_sprite("nonexistent-sprite-xyz-#{System.unique_integer()}")
    end
  end
end
