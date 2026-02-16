defmodule LatticeWeb.Plugs.AuthTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  @moduletag :unit

  alias LatticeWeb.Plugs.Auth

  # In test env, the stub provider always succeeds

  describe "call/2 with valid authorization header" do
    test "assigns current_operator from bearer token" do
      conn =
        :get
        |> conn("/api/test")
        |> put_req_header("authorization", "Bearer some-token")
        |> Auth.call(Auth.init([]))

      assert %Lattice.Auth.Operator{} = conn.assigns.current_operator
      refute conn.halted
    end
  end

  describe "call/2 without authorization header" do
    test "returns 401 with missing_authorization_header error" do
      conn =
        :get
        |> conn("/api/test")
        |> Auth.call(Auth.init([]))

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "missing_authorization_header"}
    end
  end

  describe "call/2 with malformed authorization header" do
    test "returns 401 for non-bearer token" do
      conn =
        :get
        |> conn("/api/test")
        |> put_req_header("authorization", "Basic user:pass")
        |> Auth.call(Auth.init([]))

      assert conn.halted
      assert conn.status == 401
    end
  end
end
