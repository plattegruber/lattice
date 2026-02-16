defmodule Lattice.Auth.StubTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Auth.Operator
  alias Lattice.Auth.Stub

  describe "verify_token/1" do
    test "returns a valid operator for any token" do
      assert {:ok, %Operator{}} = Stub.verify_token("any-token")
    end

    test "returns default dev operator when no config set" do
      assert {:ok, %Operator{id: "dev-operator", name: "Dev Operator", role: :admin}} =
               Stub.verify_token("ignored")
    end

    test "returns configured stub operator" do
      original = Application.get_env(:lattice, :auth)

      Application.put_env(:lattice, :auth,
        provider: Lattice.Auth.Stub,
        stub_operator: %{id: "custom-1", name: "Custom Op", role: :viewer}
      )

      assert {:ok, %Operator{id: "custom-1", name: "Custom Op", role: :viewer}} =
               Stub.verify_token("anything")

      Application.put_env(:lattice, :auth, original)
    end

    test "accepts nil token" do
      assert {:ok, %Operator{}} = Stub.verify_token(nil)
    end
  end
end
