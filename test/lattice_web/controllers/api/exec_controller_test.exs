defmodule LatticeWeb.Api.ExecControllerTest do
  use LatticeWeb.ConnCase

  alias Lattice.Sprites.ExecSession
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite

  @moduletag :unit

  # Minimal GenServer that registers in ExecRegistry like ExecSession does,
  # for testing session management endpoints without needing an API token.
  defmodule TestSession do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    @impl true
    def init(args) do
      sprite_id = Keyword.fetch!(args, :sprite_id)
      command = Keyword.fetch!(args, :command)

      session_id =
        "exec_test_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

      {:ok, _} =
        Registry.register(Lattice.Sprites.ExecRegistry, session_id, %{
          sprite_id: sprite_id,
          command: command
        })

      {:ok,
       %{
         session_id: session_id,
         sprite_id: sprite_id,
         command: command,
         status: :running,
         started_at: DateTime.utc_now(),
         buffer_size: 0,
         exit_code: nil
       }}
    end

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, {:ok, state}, state}
    def handle_call(:get_output, _from, state), do: {:reply, {:ok, []}, state}
    def handle_call(:close, _from, state), do: {:stop, :normal, :ok, %{state | status: :closed}}
  end

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
    end)

    :ok
  end

  defp start_stub_session(sprite_id, command \\ "echo test") do
    args = [sprite_id: sprite_id, command: command]

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Lattice.Sprites.ExecSupervisor,
        {TestSession, args}
      )

    {:ok, state} = ExecSession.get_state(pid)
    {pid, state.session_id}
  end

  # ── POST /api/sprites/:id/exec ──────────────────────────────────────

  describe "POST /api/sprites/:id/exec" do
    test "returns 404 when sprite does not exist", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/nonexistent/exec", %{"command" => "echo hello"})

      body = json_response(conn, 404)

      assert body["error"] == "Sprite not found"
      assert body["code"] == "SPRITE_NOT_FOUND"
    end

    test "returns 422 when command is missing", %{conn: conn} do
      start_sprite("exec-sprite-422")

      conn =
        conn
        |> authenticated()
        |> post("/api/sprites/exec-sprite-422/exec", %{})

      body = json_response(conn, 422)

      assert body["error"] == "Missing required field: command"
      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/sprites/some-sprite/exec", %{"command" => "ls"})

      assert json_response(conn, 401)
    end
  end

  # ── GET /api/sprites/:id/sessions ───────────────────────────────────

  describe "GET /api/sprites/:id/sessions" do
    test "lists sessions for a sprite", %{conn: conn} do
      start_sprite("exec-list-sprite")
      {_pid, _session_id} = start_stub_session("exec-list-sprite")

      # Small delay for stub init to complete
      Process.sleep(20)

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/exec-list-sprite/sessions")

      body = json_response(conn, 200)

      assert [_ | _] = body["data"]

      session = hd(body["data"])
      assert session["sprite_id"] == "exec-list-sprite"
      assert session["command"] == "echo test"
      assert is_binary(body["timestamp"])
    end

    test "returns empty list when no sessions exist", %{conn: conn} do
      start_sprite("exec-empty-sprite")

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/exec-empty-sprite/sessions")

      body = json_response(conn, 200)

      assert body["data"] == []
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/sprites/some-sprite/sessions")

      assert json_response(conn, 401)
    end
  end

  # ── GET /api/sprites/:id/sessions/:session_id ──────────────────────

  describe "GET /api/sprites/:id/sessions/:session_id" do
    test "returns session details with output", %{conn: conn} do
      start_sprite("exec-show-sprite")
      {_pid, session_id} = start_stub_session("exec-show-sprite", "date")

      # Query immediately -- the stub is alive and responding.
      # Output buffer may be empty since output arrives after 100ms,
      # but the session state and output list should be accessible.
      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/exec-show-sprite/sessions/#{session_id}")

      body = json_response(conn, 200)

      assert body["data"]["session_id"] == session_id
      assert body["data"]["sprite_id"] == "exec-show-sprite"
      assert body["data"]["command"] == "date"
      assert is_list(body["data"]["output"])
      assert is_binary(body["timestamp"])
    end

    test "returns 404 for unknown session", %{conn: conn} do
      start_sprite("exec-show-sprite-404")

      conn =
        conn
        |> authenticated()
        |> get("/api/sprites/exec-show-sprite-404/sessions/nonexistent-session")

      body = json_response(conn, 404)

      assert body["error"] == "Session not found"
      assert body["code"] == "SESSION_NOT_FOUND"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/sprites/some-sprite/sessions/some-session")

      assert json_response(conn, 401)
    end
  end

  # ── DELETE /api/sprites/:id/sessions/:session_id ────────────────────

  describe "DELETE /api/sprites/:id/sessions/:session_id" do
    test "terminates a session", %{conn: conn} do
      start_sprite("exec-delete-sprite")
      {pid, session_id} = start_stub_session("exec-delete-sprite")
      ref = Process.monitor(pid)

      conn =
        conn
        |> authenticated()
        |> delete("/api/sprites/exec-delete-sprite/sessions/#{session_id}")

      body = json_response(conn, 200)

      assert body["data"]["session_id"] == session_id
      assert body["data"]["status"] == "closed"

      # Verify the process terminated
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end

    test "returns 404 for unknown session", %{conn: conn} do
      start_sprite("exec-delete-sprite-404")

      conn =
        conn
        |> authenticated()
        |> delete("/api/sprites/exec-delete-sprite-404/sessions/nonexistent-session")

      body = json_response(conn, 404)

      assert body["error"] == "Session not found"
      assert body["code"] == "SESSION_NOT_FOUND"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = delete(conn, "/api/sprites/some-sprite/sessions/some-session")

      assert json_response(conn, 401)
    end
  end
end
