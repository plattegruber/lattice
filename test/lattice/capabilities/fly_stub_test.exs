defmodule Lattice.Capabilities.Fly.StubTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.Fly.Stub

  describe "deploy/1" do
    test "returns a deployment result" do
      config = %{app: "my-app", region: "lax"}
      assert {:ok, result} = Stub.deploy(config)
      assert result.app == "my-app"
      assert result.region == "lax"
      assert result.status == "started"
      assert is_binary(result.machine_id)
    end

    test "uses defaults when config is minimal" do
      assert {:ok, result} = Stub.deploy(%{})
      assert result.app == "lattice-dev"
      assert result.region == "iad"
    end
  end

  describe "logs/2" do
    test "returns log lines for a machine" do
      assert {:ok, [first | _rest]} = Stub.logs("mach-123", [])
      assert is_binary(first)
    end

    test "includes the machine ID in log output" do
      assert {:ok, logs} = Stub.logs("mach-456", [])
      assert Enum.any?(logs, &String.contains?(&1, "mach-456"))
    end
  end

  describe "machine_status/1" do
    test "returns status for a machine" do
      assert {:ok, status} = Stub.machine_status("mach-789")
      assert status.machine_id == "mach-789"
      assert status.state == "started"
      assert is_binary(status.region)
      assert is_list(status.checks)
    end
  end
end
