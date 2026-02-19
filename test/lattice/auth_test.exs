defmodule Lattice.AuthTest do
  use ExUnit.Case, async: true

  import Mox

  @moduletag :unit

  alias Lattice.Auth
  alias Lattice.Auth.Operator

  setup :verify_on_exit!

  describe "verify_token/1" do
    test "delegates to the configured provider" do
      Lattice.MockAuth
      |> expect(:verify_token, fn "test-token" ->
        {:ok, %Operator{id: "op-1", name: "Test Op", role: :admin}}
      end)

      assert {:ok, %Operator{id: "op-1"}} = Auth.verify_token("test-token")
    end

    test "returns error when provider denies" do
      Lattice.MockAuth
      |> expect(:verify_token, fn _ -> {:error, :invalid_token} end)

      assert {:error, :invalid_token} = Auth.verify_token("bad-token")
    end
  end

  describe "provider/0" do
    test "returns the configured provider module" do
      assert Auth.provider() == Lattice.MockAuth
    end
  end
end
