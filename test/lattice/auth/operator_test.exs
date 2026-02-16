defmodule Lattice.Auth.OperatorTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Auth.Operator

  describe "new/3" do
    test "creates an operator with valid role" do
      assert {:ok, %Operator{id: "user_1", name: "Ada", role: :admin}} =
               Operator.new("user_1", "Ada", :admin)
    end

    test "accepts all valid roles" do
      for role <- [:viewer, :operator, :admin] do
        assert {:ok, %Operator{role: ^role}} = Operator.new("id", "name", role)
      end
    end

    test "rejects invalid role" do
      assert {:error, {:invalid_role, :superadmin}} = Operator.new("id", "name", :superadmin)
    end
  end

  describe "has_role?/2" do
    test "admin has all roles" do
      {:ok, op} = Operator.new("1", "Ada", :admin)

      assert Operator.has_role?(op, :viewer)
      assert Operator.has_role?(op, :operator)
      assert Operator.has_role?(op, :admin)
    end

    test "operator has viewer and operator roles" do
      {:ok, op} = Operator.new("1", "Ada", :operator)

      assert Operator.has_role?(op, :viewer)
      assert Operator.has_role?(op, :operator)
      refute Operator.has_role?(op, :admin)
    end

    test "viewer has only viewer role" do
      {:ok, op} = Operator.new("1", "Ada", :viewer)

      assert Operator.has_role?(op, :viewer)
      refute Operator.has_role?(op, :operator)
      refute Operator.has_role?(op, :admin)
    end
  end

  describe "valid_roles/0" do
    test "returns all valid roles" do
      assert Operator.valid_roles() == [:viewer, :operator, :admin]
    end
  end
end
