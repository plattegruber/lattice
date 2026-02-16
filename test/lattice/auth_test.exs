defmodule Lattice.AuthTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Auth
  alias Lattice.Auth.Operator

  describe "verify_token/1" do
    test "delegates to the configured provider (stub in test)" do
      assert {:ok, %Operator{}} = Auth.verify_token("any-token")
    end
  end

  describe "provider/0" do
    test "returns the configured provider module" do
      assert Auth.provider() == Lattice.Auth.Stub
    end
  end
end
