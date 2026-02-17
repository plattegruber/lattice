defmodule LatticeWeb.Api.TaskControllerTest do
  use LatticeWeb.ConnCase

  alias Lattice.Intents.Store.ETS, as: StoreETS
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite

  @moduletag :unit

  setup do
    StoreETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  defp start_sprite(sprite_id, opts \\ []) do
    desired = Keyword.get(opts, :desired_state, :hibernating)

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Lattice.Sprites.DynamicSupervisor,
        {Sprite,
         [
           sprite_id: sprite_id,
           desired_state: desired,
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
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(Lattice.Sprites.DynamicSupervisor, pid)

        _ ->
          :ok
      end
    end)

    :ok
  end

  defp valid_task_params do
    %{
      "repo" => "plattegruber/lattice",
      "task_kind" => "open_pr_trivial_change",
      "instructions" => "Add a build timestamp to README.md"
    }
  end

  defp with_guardrails(config, fun) do
    previous = Application.get_env(:lattice, :guardrails, [])
    Application.put_env(:lattice, :guardrails, config)

    try do
      fun.()
    after
      Application.put_env(:lattice, :guardrails, previous)
    end
  end

  # ── POST /api/sprites/:name/tasks ──────────────────────────────────

  describe "POST /api/sprites/:name/tasks" do
    test "creates a task intent for an existing sprite", %{conn: conn} do
      start_sprite("task-sprite-001")

      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          conn =
            conn
            |> authenticated()
            |> post("/api/sprites/task-sprite-001/tasks", valid_task_params())

          body = json_response(conn, 200)

          assert is_binary(body["data"]["intent_id"])
          assert body["data"]["state"] in ["awaiting_approval", "approved"]
          assert body["data"]["classification"] == "controlled"
          assert body["data"]["sprite_name"] == "task-sprite-001"
          assert body["data"]["repo"] == "plattegruber/lattice"
          assert is_binary(body["timestamp"])
        end
      )
    end

    test "accepts optional fields", %{conn: conn} do
      start_sprite("task-sprite-opts")

      params =
        valid_task_params()
        |> Map.put("base_branch", "develop")
        |> Map.put("pr_title", "My PR")
        |> Map.put("pr_body", "Description of changes")
        |> Map.put("summary", "Custom summary")

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/task-sprite-opts/tasks", params)

      body = json_response(conn, 200)

      assert is_binary(body["data"]["intent_id"])
      assert body["data"]["sprite_name"] == "task-sprite-opts"
    end

    test "auto-approves tasks on allowlisted repos", %{conn: conn} do
      start_sprite("task-sprite-allow")

      previous_guardrails = Application.get_env(:lattice, :guardrails, [])
      previous_allowlist = Application.get_env(:lattice, :task_allowlist, [])

      Application.put_env(:lattice, :guardrails,
        allow_controlled: true,
        require_approval_for_controlled: true
      )

      Application.put_env(:lattice, :task_allowlist, auto_approve_repos: ["plattegruber/lattice"])

      on_exit(fn ->
        Application.put_env(:lattice, :guardrails, previous_guardrails)
        Application.put_env(:lattice, :task_allowlist, previous_allowlist)
      end)

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/task-sprite-allow/tasks", valid_task_params())

      body = json_response(conn, 200)

      assert body["data"]["state"] == "approved"
      assert body["data"]["classification"] == "controlled"
    end

    test "returns 404 when sprite does not exist", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/nonexistent-sprite/tasks", valid_task_params())

      body = json_response(conn, 404)

      assert body["error"] == "Sprite not found"
      assert body["code"] == "SPRITE_NOT_FOUND"
    end

    test "returns 422 when repo is missing", %{conn: conn} do
      start_sprite("task-sprite-no-repo")

      params = Map.delete(valid_task_params(), "repo")

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/task-sprite-no-repo/tasks", params)

      body = json_response(conn, 422)

      assert body["error"] =~ "repo"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 when repo is empty string", %{conn: conn} do
      start_sprite("task-sprite-empty-repo")

      params = Map.put(valid_task_params(), "repo", "")

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/task-sprite-empty-repo/tasks", params)

      body = json_response(conn, 422)

      assert body["error"] =~ "repo"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 when task_kind is missing", %{conn: conn} do
      start_sprite("task-sprite-no-kind")

      params = Map.delete(valid_task_params(), "task_kind")

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/task-sprite-no-kind/tasks", params)

      body = json_response(conn, 422)

      assert body["error"] =~ "task_kind"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 when task_kind is empty string", %{conn: conn} do
      start_sprite("task-sprite-empty-kind")

      params = Map.put(valid_task_params(), "task_kind", "")

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/task-sprite-empty-kind/tasks", params)

      body = json_response(conn, 422)

      assert body["error"] =~ "task_kind"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 when instructions is missing", %{conn: conn} do
      start_sprite("task-sprite-no-instr")

      params = Map.delete(valid_task_params(), "instructions")

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/task-sprite-no-instr/tasks", params)

      body = json_response(conn, 422)

      assert body["error"] =~ "instructions"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 when instructions is empty string", %{conn: conn} do
      start_sprite("task-sprite-empty-instr")

      params = Map.put(valid_task_params(), "instructions", "")

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/task-sprite-empty-instr/tasks", params)

      body = json_response(conn, 422)

      assert body["error"] =~ "instructions"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/sprites/any-sprite/tasks", valid_task_params())

      assert json_response(conn, 401)
    end

    test "created task intent is visible via GET /api/intents", %{conn: conn} do
      start_sprite("task-sprite-list")

      conn
      |> authenticated()
      |> post("/api/sprites/task-sprite-list/tasks", valid_task_params())

      conn =
        build_conn()
        |> authenticated()
        |> get("/api/intents")

      body = json_response(conn, 200)

      assert [_ | _] = body["data"]

      task_intent = Enum.find(body["data"], &(&1["kind"] == "action"))
      assert task_intent != nil
      assert task_intent["source"]["type"] == "operator"
      assert task_intent["source"]["id"] == "api"
    end
  end
end
