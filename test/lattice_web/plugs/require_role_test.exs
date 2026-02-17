defmodule LatticeWeb.Plugs.RequireRoleTest do
  use ExUnit.Case

  import Plug.Test

  @moduletag :unit

  alias Lattice.Auth.Operator
  alias LatticeWeb.Plugs.RequireRole

  describe "init/1" do
    test "accepts valid roles" do
      assert :viewer == RequireRole.init(role: :viewer)
      assert :operator == RequireRole.init(role: :operator)
      assert :admin == RequireRole.init(role: :admin)
    end

    test "raises on invalid role" do
      assert_raise ArgumentError, fn -> RequireRole.init(role: :superadmin) end
    end

    test "raises when role is missing" do
      assert_raise KeyError, fn -> RequireRole.init([]) end
    end
  end

  describe "call/2 with sufficient role" do
    test "passes through when operator has required role" do
      {:ok, operator} = Operator.new("1", "Ada", :admin)

      conn =
        :get
        |> conn("/api/test")
        |> Plug.Conn.assign(:current_operator, operator)
        |> RequireRole.call(:operator)

      refute conn.halted
    end
  end

  describe "call/2 with insufficient role" do
    test "returns 403 when operator lacks required role" do
      {:ok, operator} = Operator.new("1", "Ada", :viewer)

      conn =
        :get
        |> conn("/api/test")
        |> Plug.Conn.assign(:current_operator, operator)
        |> RequireRole.call(:operator)

      assert conn.halted
      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "required_role" => "operator"
             }
    end
  end

  describe "call/2 without operator" do
    test "returns 401 when no operator is assigned" do
      conn =
        :get
        |> conn("/api/test")
        |> RequireRole.call(:viewer)

      assert conn.halted
      assert conn.status == 401
    end
  end
end
