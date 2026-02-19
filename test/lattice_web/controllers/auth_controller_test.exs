defmodule LatticeWeb.AuthControllerTest do
  use LatticeWeb.ConnCase, async: true

  @moduletag :unit

  describe "GET /login" do
    test "renders the login page", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200) =~ "Lattice"
      assert html_response(conn, 200) =~ "clerk-sign-in"
    end

    test "redirects to /sprites if already authenticated", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{"auth_token" => "valid-token"})
        |> get(~p"/login")

      assert redirected_to(conn) == "/sprites"
    end
  end

  describe "POST /auth/callback" do
    test "creates session on valid token", %{conn: conn} do
      Mox.expect(Lattice.MockAuth, :verify_token, fn "valid-jwt" ->
        {:ok, %Lattice.Auth.Operator{id: "user_123", name: "Ada", role: :operator}}
      end)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/auth/callback", %{token: "valid-jwt"})

      assert json_response(conn, 200)["ok"] == true
      assert json_response(conn, 200)["redirect"] == "/sprites"

      # Session should have been set
      assert get_session(conn, "auth_token") == "valid-jwt"
      assert get_session(conn, "operator_id") == "user_123"
      assert get_session(conn, "operator_name") == "Ada"
    end

    test "returns 401 on invalid token", %{conn: conn} do
      Mox.expect(Lattice.MockAuth, :verify_token, fn "bad-jwt" ->
        {:error, :invalid_signature}
      end)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/auth/callback", %{token: "bad-jwt"})

      assert json_response(conn, 401)["error"] == "Authentication failed"
    end

    test "returns 400 when token is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/auth/callback", %{})

      assert json_response(conn, 400)["error"] == "Missing token parameter"
    end
  end

  describe "GET /auth/logout" do
    test "clears session and redirects to /login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{"auth_token" => "some-token"})
        |> get(~p"/auth/logout")

      assert redirected_to(conn) == "/login"
    end
  end

  describe "GET / (root)" do
    test "redirects to /login when not authenticated", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/login"
    end

    test "redirects to /sprites when authenticated", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{"auth_token" => "valid-token"})
        |> get(~p"/")

      assert redirected_to(conn) == "/sprites"
    end
  end
end
