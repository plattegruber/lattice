defmodule Lattice.Sprites.ExecSupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Sprites.ExecSession
  alias Lattice.Sprites.ExecSupervisor

  # Minimal GenServer that registers in ExecRegistry like ExecSession does,
  # for testing the supervisor's session tracking without needing an API token.
  defmodule TestSession do
    use GenServer

    def start_link(args) do
      GenServer.start_link(__MODULE__, args)
    end

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

      state = %{
        session_id: session_id,
        sprite_id: sprite_id,
        command: command,
        status: :running,
        started_at: DateTime.utc_now(),
        buffer_size: 0,
        exit_code: nil
      }

      {:ok, state}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, {:ok, state}, state}
    end

    def handle_call(:get_output, _from, state) do
      {:reply, {:ok, []}, state}
    end

    def handle_call(:close, _from, state) do
      {:stop, :normal, :ok, state}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp start_test_session(sprite_id, command \\ "echo test") do
    args = [sprite_id: sprite_id, command: command]

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Lattice.Sprites.ExecSupervisor,
        {TestSession, args}
      )

    {:ok, state} = ExecSession.get_state(pid)
    {pid, state.session_id}
  end

  # ── Tests ──────────────────────────────────────────────────────────

  describe "list_sessions/0" do
    test "returns all active sessions" do
      {pid1, sid1} = start_test_session("sprite-a", "ls")
      {pid2, sid2} = start_test_session("sprite-b", "whoami")

      sessions = ExecSupervisor.list_sessions()

      session_ids = Enum.map(sessions, fn {session_id, _pid, _meta} -> session_id end)
      assert sid1 in session_ids
      assert sid2 in session_ids

      # Each session has the correct metadata
      s1 = Enum.find(sessions, fn {id, _, _} -> id == sid1 end)
      assert {^sid1, ^pid1, %{sprite_id: "sprite-a", command: "ls"}} = s1

      s2 = Enum.find(sessions, fn {id, _, _} -> id == sid2 end)
      assert {^sid2, ^pid2, %{sprite_id: "sprite-b", command: "whoami"}} = s2
    end
  end

  describe "list_sessions_for_sprite/1" do
    test "filters sessions by sprite_id" do
      {_pid1, sid1} = start_test_session("sprite-x", "cmd1")
      {_pid2, _sid2} = start_test_session("sprite-y", "cmd2")
      {_pid3, sid3} = start_test_session("sprite-x", "cmd3")

      sessions = ExecSupervisor.list_sessions_for_sprite("sprite-x")

      session_ids = Enum.map(sessions, fn {session_id, _pid, _meta} -> session_id end)
      assert sid1 in session_ids
      assert sid3 in session_ids
      assert length(sessions) == 2
    end

    test "returns empty list when no sessions for sprite" do
      assert ExecSupervisor.list_sessions_for_sprite("nonexistent-sprite") == []
    end
  end

  describe "get_session_pid/1" do
    test "returns pid for existing session" do
      {pid, session_id} = start_test_session("sprite-z")

      assert {:ok, ^pid} = ExecSupervisor.get_session_pid(session_id)
    end

    test "returns not_found for unknown session" do
      assert {:error, :not_found} = ExecSupervisor.get_session_pid("nonexistent-id")
    end
  end
end
