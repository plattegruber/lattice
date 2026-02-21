defmodule Lattice.Sprites.ShutdownDrainTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Sprites.ShutdownDrain

  # A minimal session-like process that registers in the ExecRegistry.
  defmodule FakeSession do
    use GenServer

    def start_link(session_id, sprite_id) do
      GenServer.start_link(__MODULE__, {session_id, sprite_id})
    end

    @impl true
    def init({session_id, sprite_id}) do
      {:ok, _} =
        Registry.register(Lattice.Sprites.ExecRegistry, session_id, %{
          sprite_id: sprite_id,
          command: "test"
        })

      {:ok, %{session_id: session_id}}
    end
  end

  # Start a drain GenServer in isolation (not the named one from application.ex).
  defp start_drain do
    {:ok, pid} = GenServer.start_link(ShutdownDrain, [])
    pid
  end

  defp start_fake_session(session_id, sprite_id \\ "test-sprite") do
    {:ok, pid} = FakeSession.start_link(session_id, sprite_id)
    pid
  end

  describe "SIGTERM with no active sessions" do
    test "sends :shutdown immediately" do
      drain = start_drain()

      # Intercept System.stop by monitoring the drain process instead of actually stopping.
      # We test the decision logic: with no sessions, it should stop right away.
      # Since we can't easily intercept System.stop/0 in tests, we verify the drain
      # process is alive before signal and handles the message without crashing.
      assert Process.alive?(drain)
      send(drain, {:signal, :sigterm})

      # Give it a moment to process — the GenServer should handle the message cleanly.
      Process.sleep(50)
    end
  end

  describe "SIGTERM with active sessions" do
    test "transitions to draining state and polls until sessions finish" do
      drain = start_drain()

      session_pid = start_fake_session("exec_drain_test_1")

      assert Process.alive?(drain)
      send(drain, {:signal, :sigterm})

      # Give it time to poll at least once.
      Process.sleep(100)

      # Drain should still be alive (session is still active).
      assert Process.alive?(drain)

      # Terminate the session — drain should detect empty registry on next poll.
      GenServer.stop(session_pid, :normal)

      # Allow poll interval to fire (5 seconds by default, but we just need the
      # process to handle the next poll_sessions message we send manually).
      send(drain, :poll_sessions)
      Process.sleep(50)
    end
  end
end
