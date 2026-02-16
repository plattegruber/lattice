defmodule Lattice.CapabilitiesTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities

  describe "impl/1" do
    test "returns the configured implementation for sprites" do
      assert Capabilities.impl(:sprites) == Lattice.Capabilities.MockSprites
    end

    test "returns the configured implementation for github" do
      assert Capabilities.impl(:github) == Lattice.Capabilities.MockGitHub
    end

    test "returns the configured implementation for fly" do
      assert Capabilities.impl(:fly) == Lattice.Capabilities.MockFly
    end

    test "returns the configured implementation for secret_store" do
      assert Capabilities.impl(:secret_store) == Lattice.Capabilities.MockSecretStore
    end

    test "raises for unconfigured capability" do
      assert_raise ArgumentError, ~r/no implementation configured/, fn ->
        Capabilities.impl(:nonexistent)
      end
    end
  end
end
