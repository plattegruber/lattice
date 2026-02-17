defmodule Lattice.Capabilities.Fly.LiveTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.Fly.Live

  describe "parse_machine_status/1" do
    test "parses a full machine status response" do
      data = %{
        "id" => "mach-abc123",
        "state" => "started",
        "region" => "ord",
        "config" => %{
          "image" => "registry.fly.io/lattice:deploy-abc"
        },
        "created_at" => "2026-02-16T10:00:00Z",
        "checks" => [
          %{"name" => "http", "status" => "passing"},
          %{"name" => "tcp", "status" => "passing"}
        ]
      }

      result = Live.parse_machine_status(data)

      assert result.machine_id == "mach-abc123"
      assert result.state == "started"
      assert result.region == "ord"
      assert result.image == "registry.fly.io/lattice:deploy-abc"
      assert result.created_at == "2026-02-16T10:00:00Z"
      assert length(result.checks) == 2
      assert hd(result.checks).name == "http"
      assert hd(result.checks).status == "passing"
    end

    test "handles missing optional fields" do
      data = %{
        "id" => "mach-minimal",
        "state" => "stopped"
      }

      result = Live.parse_machine_status(data)

      assert result.machine_id == "mach-minimal"
      assert result.state == "stopped"
      assert result.region == nil
      assert result.image == nil
      assert result.checks == []
    end

    test "handles machine_id key instead of id" do
      data = %{
        "machine_id" => "mach-alt-key",
        "state" => "started",
        "region" => "iad"
      }

      result = Live.parse_machine_status(data)

      assert result.machine_id == "mach-alt-key"
    end

    test "handles image at top level instead of nested config" do
      data = %{
        "id" => "mach-flat",
        "state" => "started",
        "image" => "lattice:latest"
      }

      result = Live.parse_machine_status(data)

      assert result.image == "lattice:latest"
    end

    test "handles non-list checks gracefully" do
      data = %{
        "id" => "mach-no-checks",
        "state" => "started",
        "checks" => nil
      }

      result = Live.parse_machine_status(data)

      assert result.checks == []
    end

    test "handles checks with missing fields" do
      data = %{
        "id" => "mach-partial-checks",
        "state" => "started",
        "checks" => [%{}]
      }

      result = Live.parse_machine_status(data)

      assert [check] = result.checks
      assert check.name == "unknown"
      assert check.status == "unknown"
    end
  end

  describe "deploy/1" do
    test "returns :not_implemented error" do
      assert {:error, :not_implemented} = Live.deploy(%{app: "test-app"})
    end
  end
end
