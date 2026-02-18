defmodule LatticeWeb.Api.SkillControllerTest do
  use LatticeWeb.ConnCase

  alias Lattice.Protocol.SkillDiscovery
  alias Lattice.Protocol.SkillManifest
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite

  @moduletag :unit

  # ── Helpers ──────────────────────────────────────────────────────────

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  defp start_sprite(sprite_id) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Lattice.Sprites.DynamicSupervisor,
        {Sprite,
         [
           sprite_id: sprite_id,
           desired_state: :hibernating,
           name: Sprite.via(sprite_id),
           reconcile_interval_ms: 600_000
         ]}
      )

    :sys.replace_state(FleetManager, fn state ->
      %{state | sprite_ids: state.sprite_ids ++ [sprite_id]}
    end)

    on_exit(fn ->
      :sys.replace_state(FleetManager, fn state ->
        %{state | sprite_ids: state.sprite_ids -- [sprite_id]}
      end)

      case Registry.lookup(Lattice.Sprites.Registry, sprite_id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Lattice.Sprites.DynamicSupervisor, pid)
        _ -> :ok
      end

      # Clean up skill cache
      SkillDiscovery.invalidate(sprite_id)
    end)

    :ok
  end

  defp seed_skill_cache(sprite_name, skills) do
    # Ensure the ETS table exists (lazy init like the module does)
    if :ets.whereis(:lattice_skill_cache) == :undefined do
      :ets.new(:lattice_skill_cache, [:named_table, :public, :set, read_concurrency: true])
    end

    # Write directly to the cache table
    :ets.insert(:lattice_skill_cache, {sprite_name, skills, System.monotonic_time(:millisecond)})

    on_exit(fn -> SkillDiscovery.invalidate(sprite_name) end)
  end

  defp sample_manifests do
    [
      %SkillManifest{
        name: "open_pr",
        description: "Opens a pull request",
        inputs: [
          %Lattice.Protocol.SkillInput{
            name: "repo",
            type: :string,
            required: true,
            description: "Target repository"
          }
        ],
        outputs: [
          %Lattice.Protocol.SkillOutput{
            name: "pr_url",
            type: "string",
            description: "PR URL"
          }
        ],
        permissions: ["github:write"],
        produces_events: true
      },
      %SkillManifest{
        name: "run_tests",
        description: "Runs the test suite",
        inputs: [],
        outputs: [],
        permissions: [],
        produces_events: false
      }
    ]
  end

  # ── GET /api/sprites/:name/skills ────────────────────────────────────

  describe "GET /api/sprites/:name/skills" do
    test "returns 404 when sprite does not exist", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/nonexistent/skills")

      body = json_response(conn, 404)

      assert body["error"] == "Sprite not found"
      assert body["code"] == "SPRITE_NOT_FOUND"
    end

    test "returns cached skills for a sprite", %{conn: conn} do
      start_sprite("skill-list-sprite")
      seed_skill_cache("skill-list-sprite", sample_manifests())

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/skill-list-sprite/skills")

      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert length(body["data"]) == 2
      assert is_binary(body["timestamp"])

      [skill1, skill2] = body["data"]
      assert skill1["name"] == "open_pr"
      assert skill1["description"] == "Opens a pull request"
      assert skill1["input_count"] == 1
      assert skill1["output_count"] == 1
      assert skill1["permissions"] == ["github:write"]
      assert skill1["produces_events"] == true

      assert skill2["name"] == "run_tests"
    end

    test "returns empty list when sprite has no skills", %{conn: conn} do
      start_sprite("skill-empty-sprite")
      seed_skill_cache("skill-empty-sprite", [])

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/skill-empty-sprite/skills")

      body = json_response(conn, 200)

      assert body["data"] == []
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/sprites/some-sprite/skills")

      assert json_response(conn, 401)
    end
  end

  # ── GET /api/sprites/:name/skills/:skill_name ───────────────────────

  describe "GET /api/sprites/:name/skills/:skill_name" do
    test "returns skill detail", %{conn: conn} do
      start_sprite("skill-detail-sprite")
      seed_skill_cache("skill-detail-sprite", sample_manifests())

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/skill-detail-sprite/skills/open_pr")

      body = json_response(conn, 200)

      assert body["data"]["name"] == "open_pr"
      assert body["data"]["description"] == "Opens a pull request"
      assert is_list(body["data"]["inputs"])
      assert is_list(body["data"]["outputs"])

      [input] = body["data"]["inputs"]
      assert input["name"] == "repo"
      assert input["type"] == "string"
      assert input["required"] == true

      [output] = body["data"]["outputs"]
      assert output["name"] == "pr_url"
      assert output["type"] == "string"
    end

    test "returns 404 when sprite does not exist", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/nonexistent/skills/open_pr")

      body = json_response(conn, 404)

      assert body["error"] == "Sprite not found"
      assert body["code"] == "SPRITE_NOT_FOUND"
    end

    test "returns 404 when skill does not exist", %{conn: conn} do
      start_sprite("skill-notfound-sprite")
      seed_skill_cache("skill-notfound-sprite", sample_manifests())

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/skill-notfound-sprite/skills/nonexistent")

      body = json_response(conn, 404)

      assert body["error"] == "Skill not found"
      assert body["code"] == "SKILL_NOT_FOUND"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/sprites/some-sprite/skills/some-skill")

      assert json_response(conn, 401)
    end
  end
end
