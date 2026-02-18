defmodule Lattice.AuthTest do
  use ExUnit.Case

  import Mox

  @moduletag :unit

  alias Lattice.Auth
  alias Lattice.Auth.Operator

  setup :verify_on_exit!

  describe "verify_token/1" do
    test "delegates to the configured provider" do
      expect(Lattice.MockAuth, :verify_token, fn "test-token" ->
        Operator.new("op-1", "Test Op", :admin)
      end)

      assert {:ok, %Operator{id: "op-1"}} = Auth.verify_token("test-token")
    end
  end

  describe "provider/0" do
    test "returns the configured provider module" do
      assert Auth.provider() == Lattice.MockAuth
    end
  end
end
