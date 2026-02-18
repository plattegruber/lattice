defmodule Lattice.Runs.RunTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Runs.Run

  # ── new/1 ────────────────────────────────────────────────────────────

  describe "new/1" do
    test "creates a run with generated id and defaults" do
      assert {:ok, run} = Run.new(sprite_name: "sprite-001", mode: :exec_ws)

      assert String.starts_with?(run.id, "run_")
      assert run.sprite_name == "sprite-001"
      assert run.mode == :exec_ws
      assert run.status == :pending
      assert run.intent_id == nil
      assert run.command == nil
      assert run.artifacts == []
      assert run.assumptions == []
      assert run.started_at == nil
      assert run.finished_at == nil
      assert run.exit_code == nil
      assert run.error == nil
      assert %DateTime{} = run.inserted_at
      assert %DateTime{} = run.updated_at
    end

    test "accepts optional fields" do
      assert {:ok, run} =
               Run.new(
                 sprite_name: "sprite-002",
                 mode: :exec_post,
                 intent_id: "int_abc123",
                 command: "mix test",
                 artifacts: [%{"log" => "output.txt"}]
               )

      assert run.intent_id == "int_abc123"
      assert run.command == "mix test"
      assert run.mode == :exec_post
      assert run.artifacts == [%{"log" => "output.txt"}]
    end

    test "defaults mode to :exec_ws" do
      assert {:ok, run} = Run.new(sprite_name: "sprite-001")

      assert run.mode == :exec_ws
    end

    test "returns error when sprite_name is missing" do
      assert {:error, {:missing_field, :sprite_name}} = Run.new(mode: :exec_ws)
    end

    test "returns error for invalid mode" do
      assert {:error, {:invalid_mode, :bogus}} = Run.new(sprite_name: "s1", mode: :bogus)
    end

    test "accepts a map of attrs" do
      assert {:ok, run} = Run.new(%{sprite_name: "sprite-001", mode: :service})

      assert run.sprite_name == "sprite-001"
      assert run.mode == :service
    end

    test "generates unique ids" do
      {:ok, run1} = Run.new(sprite_name: "s1")
      {:ok, run2} = Run.new(sprite_name: "s2")

      assert run1.id != run2.id
    end
  end

  # ── start/1 ──────────────────────────────────────────────────────────

  describe "start/1" do
    test "transitions pending to running" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      assert run.status == :pending

      assert {:ok, started} = Run.start(run)
      assert started.status == :running
      assert %DateTime{} = started.started_at
      assert %DateTime{} = started.updated_at
    end

    test "rejects transition from non-pending state" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      assert {:error, {:invalid_transition, :running, :running}} = Run.start(running)
    end
  end

  # ── complete/2 ───────────────────────────────────────────────────────

  describe "complete/2" do
    test "transitions running to succeeded" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      assert {:ok, completed} = Run.complete(running)
      assert completed.status == :succeeded
      assert completed.exit_code == 0
      assert %DateTime{} = completed.finished_at
    end

    test "concatenates artifacts on completion" do
      {:ok, run} =
        Run.new(sprite_name: "sprite-001", artifacts: [%{type: "initial", data: "data"}])

      {:ok, running} = Run.start(run)

      assert {:ok, completed} =
               Run.complete(running, %{
                 artifacts: [%{type: "pr_url", data: "https://github.com/pr/1"}]
               })

      assert completed.artifacts == [
               %{type: "initial", data: "data"},
               %{type: "pr_url", data: "https://github.com/pr/1"}
             ]
    end

    test "accepts custom exit_code" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      assert {:ok, completed} = Run.complete(running, %{exit_code: 42})
      assert completed.exit_code == 42
    end

    test "rejects transition from pending" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")

      assert {:error, {:invalid_transition, :pending, :succeeded}} = Run.complete(run)
    end

    test "rejects transition from succeeded" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, completed} = Run.complete(running)

      assert {:error, {:invalid_transition, :succeeded, :succeeded}} = Run.complete(completed)
    end
  end

  # ── fail/2 ───────────────────────────────────────────────────────────

  describe "fail/2" do
    test "transitions running to failed" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      assert {:ok, failed} = Run.fail(running, %{error: "timeout", exit_code: 1})
      assert failed.status == :failed
      assert failed.error == "timeout"
      assert failed.exit_code == 1
      assert %DateTime{} = failed.finished_at
    end

    test "defaults to nil error and exit_code" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      assert {:ok, failed} = Run.fail(running)
      assert failed.error == nil
      assert failed.exit_code == nil
    end

    test "rejects transition from pending" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")

      assert {:error, {:invalid_transition, :pending, :failed}} = Run.fail(run)
    end

    test "rejects transition from failed" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, failed} = Run.fail(running)

      assert {:error, {:invalid_transition, :failed, :failed}} = Run.fail(failed)
    end
  end

  # ── cancel/1 ─────────────────────────────────────────────────────────

  describe "cancel/1" do
    test "cancels a pending run" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")

      assert {:ok, canceled} = Run.cancel(run)
      assert canceled.status == :canceled
      assert %DateTime{} = canceled.finished_at
    end

    test "cancels a running run" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      assert {:ok, canceled} = Run.cancel(running)
      assert canceled.status == :canceled
      assert %DateTime{} = canceled.finished_at
    end

    test "rejects cancel from succeeded" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, completed} = Run.complete(running)

      assert {:error, {:invalid_transition, :succeeded, :canceled}} = Run.cancel(completed)
    end

    test "rejects cancel from failed" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, failed} = Run.fail(running)

      assert {:error, {:invalid_transition, :failed, :canceled}} = Run.cancel(failed)
    end

    test "rejects cancel from canceled" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, canceled} = Run.cancel(run)

      assert {:error, {:invalid_transition, :canceled, :canceled}} = Run.cancel(canceled)
    end
  end

  # ── block/2 ──────────────────────────────────────────────────────────

  describe "block/2" do
    test "blocks a running run" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      assert {:ok, blocked} = Run.block(running, "waiting for CI")
      assert blocked.status == :blocked
      assert blocked.blocked_reason == "waiting for CI"
      assert %DateTime{} = blocked.updated_at
    end

    test "rejects block from pending" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")

      assert {:error, {:invalid_transition, :pending, :blocked}} = Run.block(run, "reason")
    end

    test "rejects block from blocked" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, blocked} = Run.block(running, "first reason")

      assert {:error, {:invalid_transition, :blocked, :blocked}} =
               Run.block(blocked, "second reason")
    end

    test "rejects block from succeeded" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, completed} = Run.complete(running)

      assert {:error, {:invalid_transition, :succeeded, :blocked}} =
               Run.block(completed, "reason")
    end
  end

  # ── block_for_input/2 ──────────────────────────────────────────────

  describe "block_for_input/2" do
    test "blocks a running run for user input" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      question = %{prompt: "Which branch?", choices: ["main", "dev"], default: "main"}
      assert {:ok, blocked} = Run.block_for_input(running, question)
      assert blocked.status == :blocked_waiting_for_user
      assert blocked.question == question
      assert %DateTime{} = blocked.updated_at
    end

    test "rejects block_for_input from pending" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")

      assert {:error, {:invalid_transition, :pending, :blocked_waiting_for_user}} =
               Run.block_for_input(run, %{prompt: "?"})
    end

    test "rejects block_for_input from blocked" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, blocked} = Run.block(running, "reason")

      assert {:error, {:invalid_transition, :blocked, :blocked_waiting_for_user}} =
               Run.block_for_input(blocked, %{prompt: "?"})
    end
  end

  # ── resume/2 ────────────────────────────────────────────────────────

  describe "resume/2" do
    test "resumes a blocked run without answer" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, blocked} = Run.block(running, "waiting")

      assert {:ok, resumed} = Run.resume(blocked)
      assert resumed.status == :running
      assert resumed.answer == nil
      assert %DateTime{} = resumed.updated_at
    end

    test "resumes a blocked_waiting_for_user run with answer" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, blocked} = Run.block_for_input(running, %{prompt: "Which branch?"})

      answer = %{selected: "main", answered_by: "operator"}
      assert {:ok, resumed} = Run.resume(blocked, answer)
      assert resumed.status == :running
      assert resumed.answer == answer
    end

    test "rejects resume from running" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)

      assert {:error, {:invalid_transition, :running, :running}} = Run.resume(running)
    end

    test "rejects resume from pending" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")

      assert {:error, {:invalid_transition, :pending, :running}} = Run.resume(run)
    end

    test "rejects resume from succeeded" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, completed} = Run.complete(running)

      assert {:error, {:invalid_transition, :succeeded, :running}} = Run.resume(completed)
    end
  end

  # ── cancel from blocked states ─────────────────────────────────────

  describe "cancel/1 from blocked states" do
    test "cancels a blocked run" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, blocked} = Run.block(running, "waiting")

      assert {:ok, canceled} = Run.cancel(blocked)
      assert canceled.status == :canceled
      assert %DateTime{} = canceled.finished_at
    end

    test "cancels a blocked_waiting_for_user run" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, blocked} = Run.block_for_input(running, %{prompt: "?"})

      assert {:ok, canceled} = Run.cancel(blocked)
      assert canceled.status == :canceled
      assert %DateTime{} = canceled.finished_at
    end
  end

  # ── fail from blocked states ───────────────────────────────────────

  describe "fail/2 from blocked states" do
    test "fails a blocked run" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, blocked} = Run.block(running, "waiting")

      assert {:ok, failed} = Run.fail(blocked, %{error: "timed out while blocked"})
      assert failed.status == :failed
      assert failed.error == "timed out while blocked"
      assert %DateTime{} = failed.finished_at
    end

    test "fails a blocked_waiting_for_user run" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      {:ok, running} = Run.start(run)
      {:ok, blocked} = Run.block_for_input(running, %{prompt: "?"})

      assert {:ok, failed} = Run.fail(blocked, %{error: "abandoned"})
      assert failed.status == :failed
      assert failed.error == "abandoned"
    end
  end

  # ── add_artifacts/2 ──────────────────────────────────────────────────

  describe "add_artifact/2" do
    test "appends a single artifact to the list" do
      {:ok, run} = Run.new(sprite_name: "sprite-001", artifacts: [%{type: "a", data: 1}])
      updated = Run.add_artifact(run, %{type: "b", data: 2})

      assert updated.artifacts == [%{type: "a", data: 1}, %{type: "b", data: 2}]
    end

    test "updates updated_at timestamp" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      old_updated = run.updated_at
      Process.sleep(1)
      updated = Run.add_artifact(run, %{type: "a", data: 1})

      assert DateTime.compare(updated.updated_at, old_updated) in [:gt, :eq]
    end
  end

  describe "add_artifacts/2" do
    test "appends list of artifacts" do
      {:ok, run} = Run.new(sprite_name: "sprite-001", artifacts: [%{type: "a", data: 1}])
      updated = Run.add_artifacts(run, [%{type: "b", data: 2}, %{type: "c", data: 3}])

      assert updated.artifacts == [
               %{type: "a", data: 1},
               %{type: "b", data: 2},
               %{type: "c", data: 3}
             ]
    end

    test "handles map argument for backwards compatibility" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      updated = Run.add_artifacts(run, %{type: "a", data: 1})

      assert updated.artifacts == [%{type: "a", data: 1}]
    end

    test "appends empty list without changing artifacts" do
      {:ok, run} = Run.new(sprite_name: "sprite-001", artifacts: [%{type: "a", data: 1}])
      updated = Run.add_artifacts(run, [])

      assert updated.artifacts == [%{type: "a", data: 1}]
    end
  end

  # ── add_assumption/2 ────────────────────────────────────────────────

  describe "add_assumption/2" do
    test "adds assumption to the list" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      assert run.assumptions == []

      assumption = %{path: "lib/foo.ex", lines: [1, 10], note: "unchanged since last read"}
      updated = Run.add_assumption(run, assumption)

      assert length(updated.assumptions) == 1
      assert hd(updated.assumptions).path == "lib/foo.ex"
      assert hd(updated.assumptions).lines == [1, 10]
      assert hd(updated.assumptions).note == "unchanged since last read"
    end

    test "includes timestamp" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      assumption = %{path: "lib/bar.ex", lines: [], note: "stable API"}
      updated = Run.add_assumption(run, assumption)

      assert %DateTime{} = hd(updated.assumptions).timestamp
    end

    test "preserves existing timestamp if provided" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      ts = ~U[2026-01-15 10:00:00Z]
      assumption = %{path: "lib/baz.ex", lines: [5], note: "pinned", timestamp: ts}
      updated = Run.add_assumption(run, assumption)

      assert hd(updated.assumptions).timestamp == ts
    end

    test "appends multiple assumptions" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")

      updated =
        run
        |> Run.add_assumption(%{path: "a.ex", lines: [], note: "first"})
        |> Run.add_assumption(%{path: "b.ex", lines: [], note: "second"})

      assert length(updated.assumptions) == 2
      assert Enum.at(updated.assumptions, 0).path == "a.ex"
      assert Enum.at(updated.assumptions, 1).path == "b.ex"
    end

    test "updates updated_at timestamp" do
      {:ok, run} = Run.new(sprite_name: "sprite-001")
      old_updated = run.updated_at
      Process.sleep(1)
      updated = Run.add_assumption(run, %{path: "c.ex", lines: [], note: "test"})

      assert DateTime.compare(updated.updated_at, old_updated) in [:gt, :eq]
    end
  end
end
