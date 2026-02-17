defmodule Lattice.Capabilities.Sprites.LiveTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.Sprites.Live

  describe "parse_sprite/1" do
    test "maps API response fields to internal structure" do
      api_response = %{
        "id" => "abc-123",
        "name" => "my-sprite",
        "status" => "running",
        "organization" => "plattegruber",
        "url" => "https://my-sprite.sprites.dev",
        "created_at" => "2026-02-16T08:00:00Z",
        "updated_at" => "2026-02-16T09:00:00Z",
        "last_started_at" => "2026-02-16T08:30:00Z",
        "last_active_at" => "2026-02-16T09:00:00Z"
      }

      result = Live.parse_sprite(api_response)

      assert result.id == "my-sprite"
      assert result.name == "my-sprite"
      assert result.status == :ready
      assert result.organization == "plattegruber"
      assert result.url == "https://my-sprite.sprites.dev"
      assert result.created_at == "2026-02-16T08:00:00Z"
      assert result.updated_at == "2026-02-16T09:00:00Z"
      assert result.last_started_at == "2026-02-16T08:30:00Z"
      assert result.last_active_at == "2026-02-16T09:00:00Z"
    end

    test "uses name as id fallback when id is missing" do
      api_response = %{
        "name" => "my-sprite",
        "status" => "cold"
      }

      result = Live.parse_sprite(api_response)

      assert result.id == "my-sprite"
      assert result.name == "my-sprite"
    end

    test "handles nil fields gracefully" do
      api_response = %{
        "id" => "abc-123",
        "name" => "my-sprite",
        "status" => "warm",
        "organization" => nil,
        "url" => nil,
        "created_at" => nil,
        "updated_at" => nil,
        "last_started_at" => nil,
        "last_active_at" => nil
      }

      result = Live.parse_sprite(api_response)

      assert result.id == "my-sprite"
      assert result.status == :waking
      assert result.organization == nil
    end
  end

  describe "parse_status/1" do
    test "maps 'cold' to :hibernating" do
      assert Live.parse_status("cold") == :hibernating
    end

    test "maps 'warm' to :waking" do
      assert Live.parse_status("warm") == :waking
    end

    test "maps 'running' to :ready" do
      assert Live.parse_status("running") == :ready
    end

    test "maps nil to :error" do
      assert Live.parse_status(nil) == :error
    end

    test "maps unknown status to :error" do
      assert Live.parse_status("unknown") == :error
    end
  end
end
