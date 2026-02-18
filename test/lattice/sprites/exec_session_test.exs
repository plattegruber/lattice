defmodule Lattice.Sprites.ExecSessionTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Sprites.ExecSession
  alias Lattice.Sprites.ExecSession.Stub

  # ── Helpers ─────────────────────────────────────────────────────────

  defp start_stub(opts \\ []) do
    sprite_id = Keyword.get(opts, :sprite_id, "test-sprite")
    command = Keyword.get(opts, :command, "echo hello")
    idle_timeout = Keyword.get(opts, :idle_timeout, 300_000)

    args = [sprite_id: sprite_id, command: command, idle_timeout: idle_timeout]
    {:ok, pid} = GenServer.start_link(Stub, args)
    pid
  end

  # ── Tests ───────────────────────────────────────────────────────────

  describe "ExecSession.Stub" do
    test "starts and is alive" do
      pid = start_stub()
      assert Process.alive?(pid)
    end

    test "get_state returns session info" do
      pid = start_stub(sprite_id: "atlas", command: "ls -la")

      {:ok, state} = ExecSession.get_state(pid)

      assert state.sprite_id == "atlas"
      assert state.command == "ls -la"
      assert state.status == :running
      assert is_binary(state.session_id)
      assert String.starts_with?(state.session_id, "exec_stub_")
      assert %DateTime{} = state.started_at
    end

    test "broadcasts output via PubSub" do
      pid = start_stub(sprite_id: "beacon", command: "whoami")

      {:ok, state} = ExecSession.get_state(pid)
      Phoenix.PubSub.subscribe(Lattice.PubSub, ExecSession.exec_topic(state.session_id))

      # Wait for simulated output (100ms delay + 50ms exit)
      assert_receive {:exec_output, %{stream: :stdout, chunk: "$ whoami"}}, 500
      assert_receive {:exec_output, %{stream: :stdout, chunk: "Executing on beacon..."}}, 500
      assert_receive {:exec_output, %{stream: :stdout, chunk: "Done."}}, 500
      assert_receive {:exec_output, %{stream: :exit}}, 500
    end

    test "get_output returns buffered output" do
      pid = start_stub(sprite_id: "cipher", command: "date")

      {:ok, state} = ExecSession.get_state(pid)
      Phoenix.PubSub.subscribe(Lattice.PubSub, ExecSession.exec_topic(state.session_id))

      # Wait for the stdout output but query before exit completes
      assert_receive {:exec_output, %{stream: :stdout, chunk: "Done."}}, 500

      {:ok, output} = ExecSession.get_output(pid)

      assert length(output) == 3
      assert Enum.at(output, 0).stream == :stdout
      assert Enum.at(output, 0).data == "$ date"
      assert Enum.at(output, 1).data == "Executing on cipher..."
      assert Enum.at(output, 2).data == "Done."
    end

    test "close stops the session" do
      pid = start_stub()
      ref = Process.monitor(pid)

      :ok = ExecSession.close(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end

    test "session stops after simulated exit" do
      pid = start_stub()
      ref = Process.monitor(pid)

      # The stub sends simulated output after 100ms, then exits after another 50ms
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end

  describe "exec_topic/1" do
    test "returns namespaced topic" do
      assert ExecSession.exec_topic("exec_abc123") == "exec:exec_abc123"
    end
  end
end
