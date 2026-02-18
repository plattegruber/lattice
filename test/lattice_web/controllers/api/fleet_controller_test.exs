defmodule LatticeWeb.Api.FleetControllerTest do
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
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Lattice.Sprites.DynamicSupervisor,
        {Sprite,
         [
           sprite_id: config.id,
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

  # ── GET /api/fleet ──────────────────────────────────────────────────

  describe "GET /api/fleet" do
    test "returns fleet summary when authenticated", %{conn: conn} do
      start_sprites([
        %{id: "api-fleet-001"},
        %{id: "api-fleet-002"}
      ])

      conn =
        conn
        |> authenticated()
        |> get("/api/fleet")

      body = json_response(conn, 200)

      assert body["data"]["total"] == 2
      assert body["data"]["by_state"]["cold"] == 2
      assert is_binary(body["timestamp"])
    end

    test "returns empty fleet summary when no sprites", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/fleet")

      body = json_response(conn, 200)

      assert body["data"]["total"] == 0
      assert body["data"]["by_state"] == %{}
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/fleet")

      assert json_response(conn, 401)
    end
  end

  # ── POST /api/fleet/audit ──────────────────────────────────────────

  describe "POST /api/fleet/audit" do
    test "triggers fleet-wide audit", %{conn: conn} do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "api-audit-001", status: :hibernating}} end)

      start_sprites([%{id: "api-audit-001"}])

      conn =
        conn
        |> authenticated()
        |> post("/api/fleet/audit")

      body = json_response(conn, 200)

      assert body["data"]["status"] == "audit_triggered"
      assert is_binary(body["timestamp"])
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/fleet/audit")

      assert json_response(conn, 401)
    end
  end
end
