defmodule LatticeWeb.Api.RunControllerTest do
  use LatticeWeb.ConnCase

  alias Lattice.Runs.Run
  alias Lattice.Runs.Store, as: RunStore

  @moduletag :unit

  setup do
    # Clean up runs between tests
    {:ok, entries} = Lattice.Store.list(:runs)

    Enum.each(entries, fn entry ->
      Lattice.Store.delete(:runs, entry._key)
    end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  defp create_run(attrs \\ []) do
    defaults = [sprite_name: "sprite-001", mode: :exec_ws]
    {:ok, run} = Run.new(Keyword.merge(defaults, attrs))
    {:ok, run} = RunStore.create(run)
    run
  end

  # ── GET /api/runs ──────────────────────────────────────────────────

  describe "GET /api/runs" do
    test "returns empty list when no runs", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/runs")

      body = json_response(conn, 200)

      assert body["data"] == []
      assert is_binary(body["timestamp"])
    end

    test "lists all runs", %{conn: conn} do
      create_run(sprite_name: "s1")
      create_run(sprite_name: "s2")

      conn =
        conn
        |> authenticated()
        |> get("/api/runs")

      body = json_response(conn, 200)

      assert length(body["data"]) == 2
    end

    test "returns run data with all fields", %{conn: conn} do
      run = create_run(sprite_name: "sprite-test", intent_id: "int_abc", command: "mix test")

      conn =
        conn
        |> authenticated()
        |> get("/api/runs")

      body = json_response(conn, 200)
      [data] = body["data"]

      assert data["id"] == run.id
      assert data["sprite_name"] == "sprite-test"
      assert data["intent_id"] == "int_abc"
      assert data["command"] == "mix test"
      assert data["mode"] == "exec_ws"
      assert data["status"] == "pending"
      assert data["artifacts"] == %{}
      assert data["exit_code"] == nil
      assert data["error"] == nil
      assert is_binary(data["inserted_at"])
      assert is_binary(data["updated_at"])
    end

    test "filters by intent_id", %{conn: conn} do
      create_run(intent_id: "int_target")
      create_run(intent_id: "int_other")

      conn =
        conn
        |> authenticated()
        |> get("/api/runs", %{"intent_id" => "int_target"})

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert hd(body["data"])["intent_id"] == "int_target"
    end

    test "filters by sprite_name", %{conn: conn} do
      create_run(sprite_name: "alpha")
      create_run(sprite_name: "beta")

      conn =
        conn
        |> authenticated()
        |> get("/api/runs", %{"sprite_name" => "alpha"})

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert hd(body["data"])["sprite_name"] == "alpha"
    end

    test "filters by status", %{conn: conn} do
      create_run(sprite_name: "s1")

      {:ok, run2} = Run.new(sprite_name: "s2", mode: :exec_ws)
      {:ok, started} = Run.start(run2)
      {:ok, _} = RunStore.create(started)

      conn =
        conn
        |> authenticated()
        |> get("/api/runs", %{"status" => "running"})

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert hd(body["data"])["status"] == "running"
    end

    test "ignores invalid status values", %{conn: conn} do
      create_run()

      conn =
        conn
        |> authenticated()
        |> get("/api/runs", %{"status" => "bogus"})

      body = json_response(conn, 200)

      # Invalid filter is ignored, returns all runs
      assert length(body["data"]) == 1
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/runs")

      assert json_response(conn, 401)
    end
  end

  # ── GET /api/runs/:id ──────────────────────────────────────────────

  describe "GET /api/runs/:id" do
    test "returns run detail", %{conn: conn} do
      run = create_run(sprite_name: "sprite-detail", intent_id: "int_xyz", command: "mix deploy")

      conn =
        conn
        |> authenticated()
        |> get("/api/runs/#{run.id}")

      body = json_response(conn, 200)

      assert body["data"]["id"] == run.id
      assert body["data"]["sprite_name"] == "sprite-detail"
      assert body["data"]["intent_id"] == "int_xyz"
      assert body["data"]["command"] == "mix deploy"
      assert body["data"]["status"] == "pending"
      assert is_binary(body["timestamp"])
    end

    test "returns 404 for unknown run", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/runs/nonexistent")

      body = json_response(conn, 404)

      assert body["error"] == "Run not found"
      assert body["code"] == "RUN_NOT_FOUND"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/runs/some-id")

      assert json_response(conn, 401)
    end
  end
end
