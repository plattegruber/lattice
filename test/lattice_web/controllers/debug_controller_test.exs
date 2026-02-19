defmodule LatticeWeb.DebugControllerTest do
  use LatticeWeb.ConnCase, async: false

  @moduletag :unit

  describe "GET /debug" do
    test "returns system info", %{conn: conn} do
      conn = get(conn, "/debug")
      assert %{"system" => system} = json_response(conn, 200)
      assert is_binary(system["elixir_version"])
      assert is_binary(system["otp_release"])
      assert is_integer(system["uptime_seconds"])
      assert is_integer(system["process_count"])
      assert is_integer(system["schedulers"])
      assert is_map(system["memory_mb"])
      assert is_number(system["memory_mb"]["total"])
    end

    test "returns fleet info", %{conn: conn} do
      conn = get(conn, "/debug")
      assert %{"fleet" => fleet} = json_response(conn, 200)
      assert is_integer(fleet["total"])
      assert is_map(fleet["by_state"])
    end

    test "returns intent info", %{conn: conn} do
      conn = get(conn, "/debug")
      assert %{"intents" => intents} = json_response(conn, 200)
      assert is_integer(intents["total"])
      assert is_map(intents["by_state"])
      assert is_map(intents["by_kind"])
      assert is_list(intents["recent"])
    end

    test "returns PR info", %{conn: conn} do
      conn = get(conn, "/debug")
      assert %{"prs" => prs} = json_response(conn, 200)
      assert is_integer(prs["open"])
      assert is_integer(prs["merged"])
      assert is_list(prs["open_prs"])
    end

    test "returns instance identity", %{conn: conn} do
      conn = get(conn, "/debug")
      assert %{"instance" => instance} = json_response(conn, 200)
      assert is_binary(instance["name"])
    end

    test "returns timestamp", %{conn: conn} do
      conn = get(conn, "/debug")
      assert %{"timestamp" => timestamp} = json_response(conn, 200)
      assert {:ok, _, _} = DateTime.from_iso8601(timestamp)
    end

    test "does not require authentication", %{conn: conn} do
      # No auth header - should still work
      conn =
        conn
        |> Map.update!(:req_headers, fn headers ->
          Enum.reject(headers, fn {k, _} -> k == "authorization" end)
        end)

      conn = get(conn, "/debug")
      assert json_response(conn, 200)
    end
  end
end
