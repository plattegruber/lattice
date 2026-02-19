defmodule LatticeWeb.Api.SearchControllerTest do
  use LatticeWeb.ConnCase

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store.ETS, as: StoreETS

  @moduletag :unit

  setup do
    StoreETS.reset()
    :ok
  end

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  defp create_intent(summary) do
    {:ok, intent} =
      Intent.new_action(%{type: :sprite, id: "sprite-001"},
        summary: summary,
        payload: %{"capability" => "sprites", "operation" => "list_sprites"},
        affected_resources: ["sprites"],
        expected_side_effects: ["none"]
      )

    {:ok, proposed} = Pipeline.propose(intent)
    proposed
  end

  describe "GET /api/search" do
    test "returns results matching query", %{conn: conn} do
      create_intent("Deploy the application")

      conn =
        conn
        |> authenticated()
        |> get(~p"/api/search?q=deploy")

      assert %{"data" => data, "query" => "deploy"} = json_response(conn, 200)
      assert is_list(data["intents"])
      assert length(data["intents"]) == 1
      assert hd(data["intents"])["summary"] == "Deploy the application"
    end

    test "returns empty results for non-matching query", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get(~p"/api/search?q=nonexistent")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["intents"] == []
      assert data["sprites"] == []
    end

    test "searches case-insensitively", %{conn: conn} do
      create_intent("UPPERCASE Test Summary")

      conn =
        conn
        |> authenticated()
        |> get(~p"/api/search?q=uppercase")

      assert %{"data" => data} = json_response(conn, 200)
      assert length(data["intents"]) == 1
    end

    test "returns 422 when query is missing", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get(~p"/api/search")

      assert %{"error" => _, "code" => "MISSING_QUERY"} = json_response(conn, 422)
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/search?q=test")
      assert json_response(conn, 401)
    end
  end
end
