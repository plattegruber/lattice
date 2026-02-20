defmodule Lattice.Capabilities.SecretStore.Test do
  use ExUnit.Case, async: true

  alias Lattice.Capabilities.MockSecretStore
  alias Lattice.Capabilities.SecretStore

  @moduletag :unit

  describe "MockSecretStore (Mox)" do
    import Mox

    setup :verify_on_exit!

    test "returns a secret when expected" do
      MockSecretStore
      |> expect(:get_secret, fn "GITHUB_TOKEN" -> {:ok, "ghp_test_token"} end)

      assert {:ok, "ghp_test_token"} =
               SecretStore.get_secret("GITHUB_TOKEN")
    end

    test "returns error for an unknown secret" do
      MockSecretStore
      |> expect(:get_secret, fn "NONEXISTENT_KEY" -> {:error, {:not_found, "NONEXISTENT_KEY"}} end)

      assert {:error, {:not_found, "NONEXISTENT_KEY"}} =
               SecretStore.get_secret("NONEXISTENT_KEY")
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
