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
      assert run.artifacts == %{}
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
                 artifacts: %{"log" => "output.txt"}
               )

      assert run.intent_id == "int_abc123"
      assert run.command == "mix test"
      assert run.mode == :exec_post
      assert run.artifacts == %{"log" => "output.txt"}
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

    test "merges artifacts on completion" do
      {:ok, run} = Run.new(sprite_name: "sprite-001", artifacts: %{"initial" => "data"})
      {:ok, running} = Run.start(run)

      assert {:ok, completed} =
               Run.complete(running, %{artifacts: %{"pr_url" => "https://github.com/pr/1"}})

      assert completed.artifacts == %{
               "initial" => "data",
               "pr_url" => "https://github.com/pr/1"
             }
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

  # ── add_artifacts/2 ──────────────────────────────────────────────────

  describe "add_artifacts/2" do
    test "merges new artifacts into existing ones" do
      {:ok, run} = Run.new(sprite_name: "sprite-001", artifacts: %{"a" => 1})
      updated = Run.add_artifacts(run, %{"b" => 2})

      assert updated.artifacts == %{"a" => 1, "b" => 2}
    end

    test "overwrites duplicate keys" do
      {:ok, run} = Run.new(sprite_name: "sprite-001", artifacts: %{"a" => 1})
      updated = Run.add_artifacts(run, %{"a" => 99})

      assert updated.artifacts == %{"a" => 99}
    end
  end
end
