defmodule LatticeWeb.HealthControllerTest do
  use LatticeWeb.ConnCase

  test "GET /health returns ok", %{conn: conn} do
    conn = get(conn, "/health")
    body = json_response(conn, 200)

    assert body["status"] == "ok"
  end

  test "GET /health includes instance identity", %{conn: conn} do
    conn = get(conn, "/health")
    body = json_response(conn, 200)

    assert is_map(body["instance"])
    assert is_binary(body["instance"]["name"])
    assert is_binary(body["instance"]["environment"])
    assert is_map(body["instance"]["resources"])
  end

  test "GET /health includes timestamp", %{conn: conn} do
    conn = get(conn, "/health")
    body = json_response(conn, 200)

    assert is_binary(body["timestamp"])
  end
end
