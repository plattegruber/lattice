defmodule LatticeWeb.Api.SpriteControllerTest do
  use LatticeWeb.ConnCase

  import Mox

  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite

  @moduletag :unit

  setup :verify_on_exit!
  setup :set_mox_global

  # ── Helpers ──────────────────────────────────────────────────────────

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  defp start_sprites(sprite_configs) do
    sprite_ids = Enum.map(sprite_configs, & &1.id)

    # Start sprite processes under the existing DynamicSupervisor
    Enum.each(sprite_configs, &start_sprite_process/1)

    # Add sprite IDs to the FleetManager's internal state
    :sys.replace_state(FleetManager, fn state ->
      %{state | sprite_ids: state.sprite_ids ++ sprite_ids}
    end)

    on_exit(fn ->
      # Remove sprite IDs from the FleetManager
      :sys.replace_state(FleetManager, fn state ->
        %{state | sprite_ids: state.sprite_ids -- sprite_ids}
      end)

      # Stop the sprite processes
      Enum.each(sprite_ids, &terminate_sprite/1)
    end)

    :ok
  end

  defp start_sprite_process(config) do
    desired = Map.get(config, :desired_state, :hibernating)

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Lattice.Sprites.DynamicSupervisor,
        {Sprite,
         [
           sprite_id: config.id,
           desired_state: desired,
           name: Sprite.via(config.id),
           reconcile_interval_ms: 600_000
         ]}
      )
  end

  defp terminate_sprite(sprite_id) do
    case Registry.lookup(Lattice.Sprites.Registry, sprite_id) do
      [{pid, _}] when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Lattice.Sprites.DynamicSupervisor, pid)

      _ ->
        :ok
    end
  end

  # ── POST /api/sprites ───────────────────────────────────────────────

  describe "POST /api/sprites" do
    test "creates a sprite and returns sprite detail", %{conn: conn} do
      Lattice.Capabilities.MockSprites
      |> expect(:create_sprite, fn "new-sprite", [] ->
        {:ok, %{id: "new-sprite", status: "cold"}}
      end)

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites", %{"name" => "new-sprite"})

      body = json_response(conn, 200)

      assert body["data"]["id"] == "new-sprite"
      assert body["data"]["observed_state"] == "hibernating"
      assert body["data"]["desired_state"] == "hibernating"
      assert is_binary(body["timestamp"])

      # Verify the sprite is now in the fleet
      conn2 =
        build_conn()
        |> authenticated()
        |> get("/api/sprites/new-sprite")

      assert json_response(conn2, 200)["data"]["id"] == "new-sprite"

      on_exit(fn -> terminate_sprite("new-sprite") end)
    end

    test "returns 422 when name is missing", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/sprites", %{})

      body = json_response(conn, 422)

      assert body["error"] == "Missing required field: name"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 when name is empty string", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/sprites", %{"name" => ""})

      body = json_response(conn, 422)

      assert body["error"] == "Missing required field: name"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 when sprite already exists", %{conn: conn} do
      start_sprites([%{id: "existing-sprite", desired_state: :hibernating}])

      Lattice.Capabilities.MockSprites
      |> expect(:create_sprite, fn "existing-sprite", [] ->
        {:ok, %{id: "existing-sprite", status: "cold"}}
      end)

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites", %{"name" => "existing-sprite"})

      body = json_response(conn, 422)

      assert body["error"] == "Sprite already exists"
      assert body["code"] == "SPRITE_ALREADY_EXISTS"
    end

    test "returns 502 when upstream API fails", %{conn: conn} do
      Lattice.Capabilities.MockSprites
      |> expect(:create_sprite, fn "fail-sprite", [] ->
        {:error, :timeout}
      end)

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites", %{"name" => "fail-sprite"})

      body = json_response(conn, 502)

      assert body["code"] == "UPSTREAM_API_ERROR"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/sprites", %{"name" => "some-sprite"})

      assert json_response(conn, 401)
    end

    test "newly created sprite appears in GET /api/sprites", %{conn: conn} do
      Lattice.Capabilities.MockSprites
      |> expect(:create_sprite, fn "list-test-sprite", [] ->
        {:ok, %{id: "list-test-sprite", status: "cold"}}
      end)

      conn
      |> authenticated()
      |> post("/api/sprites", %{"name" => "list-test-sprite"})

      conn2 =
        build_conn()
        |> authenticated()
        |> get("/api/sprites")

      body = json_response(conn2, 200)
      sprite_ids = Enum.map(body["data"], & &1["id"])
      assert "list-test-sprite" in sprite_ids

      on_exit(fn -> terminate_sprite("list-test-sprite") end)
    end
  end

  # ── GET /api/sprites ────────────────────────────────────────────────

  describe "GET /api/sprites" do
    test "lists all sprites with state", %{conn: conn} do
      start_sprites([
        %{id: "api-sprite-001", desired_state: :hibernating},
        %{id: "api-sprite-002", desired_state: :hibernating}
      ])

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites")

      body = json_response(conn, 200)

      assert length(body["data"]) == 2

      sprite_ids = Enum.map(body["data"], & &1["id"])
      assert "api-sprite-001" in sprite_ids
      assert "api-sprite-002" in sprite_ids

      first = Enum.find(body["data"], &(&1["id"] == "api-sprite-001"))
      assert first["observed_state"] == "hibernating"
      assert first["desired_state"] == "hibernating"
      assert is_binary(body["timestamp"])
    end

    test "returns empty list when no sprites", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/sprites")

      body = json_response(conn, 200)

      assert body["data"] == []
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/sprites")

      assert json_response(conn, 401)
    end
  end

  # ── GET /api/sprites/:id ───────────────────────────────────────────

  describe "GET /api/sprites/:id" do
    test "returns sprite detail when found", %{conn: conn} do
      start_sprites([%{id: "api-show-001", desired_state: :hibernating}])

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/api-show-001")

      body = json_response(conn, 200)

      assert body["data"]["id"] == "api-show-001"
      assert body["data"]["observed_state"] == "hibernating"
      assert body["data"]["desired_state"] == "hibernating"
      assert is_integer(body["data"]["failure_count"])
      assert is_binary(body["data"]["started_at"])
      assert is_binary(body["data"]["updated_at"])
      assert is_binary(body["timestamp"])
    end

    test "returns 404 for unknown sprite", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/nonexistent")

      body = json_response(conn, 404)

      assert body["error"] == "Sprite not found"
      assert body["code"] == "SPRITE_NOT_FOUND"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/sprites/some-id")

      assert json_response(conn, 401)
    end
  end

  # ── PUT /api/sprites/:id/desired ───────────────────────────────────

  describe "PUT /api/sprites/:id/desired" do
    test "updates desired state to ready", %{conn: conn} do
      start_sprites([%{id: "api-desired-001", desired_state: :hibernating}])

      conn =
        conn
        |> authenticated()
        |> put("/api/sprites/api-desired-001/desired", %{"state" => "ready"})

      body = json_response(conn, 200)

      assert body["data"]["id"] == "api-desired-001"
      assert body["data"]["desired_state"] == "ready"
    end

    test "updates desired state to hibernating", %{conn: conn} do
      start_sprites([%{id: "api-desired-002", desired_state: :ready}])

      conn =
        conn
        |> authenticated()
        |> put("/api/sprites/api-desired-002/desired", %{"state" => "hibernating"})

      body = json_response(conn, 200)

      assert body["data"]["id"] == "api-desired-002"
      assert body["data"]["desired_state"] == "hibernating"
    end

    test "returns 422 for invalid state", %{conn: conn} do
      start_sprites([%{id: "api-desired-003", desired_state: :hibernating}])

      conn =
        conn
        |> authenticated()
        |> put("/api/sprites/api-desired-003/desired", %{"state" => "invalid"})

      body = json_response(conn, 422)

      assert body["code"] == "INVALID_STATE"
    end

    test "returns 422 when state field is missing", %{conn: conn} do
      start_sprites([%{id: "api-desired-004", desired_state: :hibernating}])

      conn =
        conn
        |> authenticated()
        |> put("/api/sprites/api-desired-004/desired", %{})

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 404 for unknown sprite", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> put("/api/sprites/nonexistent/desired", %{"state" => "ready"})

      body = json_response(conn, 404)

      assert body["code"] == "SPRITE_NOT_FOUND"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = put(conn, "/api/sprites/some-id/desired", %{"state" => "ready"})

      assert json_response(conn, 401)
    end
  end

  # ── POST /api/sprites/:id/reconcile ────────────────────────────────

  describe "POST /api/sprites/:id/reconcile" do
    test "triggers reconciliation for a sprite", %{conn: conn} do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "api-recon-001", status: :hibernating}} end)

      start_sprites([%{id: "api-recon-001", desired_state: :hibernating}])

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/api-recon-001/reconcile")

      body = json_response(conn, 200)

      assert body["data"]["sprite_id"] == "api-recon-001"
      assert body["data"]["status"] == "reconciliation_triggered"
      assert is_binary(body["timestamp"])
    end

    test "returns 404 for unknown sprite", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/nonexistent/reconcile")

      body = json_response(conn, 404)

      assert body["code"] == "SPRITE_NOT_FOUND"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/sprites/some-id/reconcile")

      assert json_response(conn, 401)
    end
  end
end
