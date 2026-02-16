defmodule Lattice.Capabilities.SecretStore.Test do
  use ExUnit.Case, async: true

  @moduletag :unit

  describe "Stub" do
    alias Lattice.Capabilities.SecretStore.Stub

    test "returns a known stub secret" do
      assert {:ok, value} = Stub.get_secret("GITHUB_TOKEN")
      assert is_binary(value)
      assert String.length(value) > 0
    end

    test "returns error for an unknown secret" do
      assert {:error, {:not_found, "NONEXISTENT_KEY"}} = Stub.get_secret("NONEXISTENT_KEY")
    end
  end

  describe "Env" do
    alias Lattice.Capabilities.SecretStore.Env

    test "reads from system environment" do
      # Set a temporary env var for testing
      System.put_env("LATTICE_TEST_SECRET", "test_value_123")

      assert {:ok, "test_value_123"} = Env.get_secret("LATTICE_TEST_SECRET")

      # Clean up
      System.delete_env("LATTICE_TEST_SECRET")
    end

    test "returns error for a missing env var" do
      assert {:error, {:not_found, "DEFINITELY_NOT_SET_ENV_VAR"}} =
               Env.get_secret("DEFINITELY_NOT_SET_ENV_VAR")
    end
  end
end
