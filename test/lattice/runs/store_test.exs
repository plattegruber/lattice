defmodule Lattice.Runs.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Runs.Run
  alias Lattice.Runs.Store, as: RunStore

  setup do
    # Clean up any runs from previous tests using the raw store
    {:ok, entries} = Lattice.Store.list(:runs)

    Enum.each(entries, fn entry ->
      Lattice.Store.delete(:runs, entry._key)
    end)

    :ok
  end

  defp build_run(attrs \\ []) do
    defaults = [sprite_name: "sprite-001", mode: :exec_ws]
    {:ok, run} = Run.new(Keyword.merge(defaults, attrs))
    run
  end

  # ── create/1 ─────────────────────────────────────────────────────────

  describe "create/1" do
    test "persists and returns the run" do
      run = build_run()
      assert {:ok, ^run} = RunStore.create(run)
      assert {:ok, stored} = RunStore.get(run.id)
      assert stored.id == run.id
      assert stored.sprite_name == "sprite-001"
    end
  end

  # ── get/1 ────────────────────────────────────────────────────────────

  describe "get/1" do
    test "retrieves a run by ID" do
      run = build_run()
      {:ok, _} = RunStore.create(run)

      assert {:ok, found} = RunStore.get(run.id)
      assert found.id == run.id
      assert found.sprite_name == run.sprite_name
    end

    test "returns {:error, :not_found} for unknown ID" do
      assert {:error, :not_found} = RunStore.get("nonexistent")
    end

    test "returns clean struct without store metadata" do
      run = build_run()
      {:ok, _} = RunStore.create(run)

      {:ok, found} = RunStore.get(run.id)
      refute Map.has_key?(found, :_key)
      refute Map.has_key?(found, :_namespace)
      refute Map.has_key?(found, :_updated_at)
    end
  end

  # ── update/1 ─────────────────────────────────────────────────────────

  describe "update/1" do
    test "updates the stored run" do
      run = build_run()
      {:ok, _} = RunStore.create(run)

      {:ok, started} = Run.start(run)
      {:ok, _} = RunStore.update(started)

      {:ok, found} = RunStore.get(run.id)
      assert found.status == :running
    end
  end

  # ── list/1 ───────────────────────────────────────────────────────────

  describe "list/1" do
    test "returns all runs when no filters" do
      {:ok, _} = RunStore.create(build_run(sprite_name: "s1"))
      {:ok, _} = RunStore.create(build_run(sprite_name: "s2"))

      assert {:ok, runs} = RunStore.list()
      assert length(runs) == 2
    end

    test "returns empty list when no runs exist" do
      assert {:ok, []} = RunStore.list()
    end

    test "filters by intent_id" do
      {:ok, _} = RunStore.create(build_run(intent_id: "int_abc"))
      {:ok, _} = RunStore.create(build_run(intent_id: "int_xyz"))
      {:ok, _} = RunStore.create(build_run())

      assert {:ok, runs} = RunStore.list(%{intent_id: "int_abc"})
      assert length(runs) == 1
      assert hd(runs).intent_id == "int_abc"
    end

    test "filters by sprite_name" do
      {:ok, _} = RunStore.create(build_run(sprite_name: "alpha"))
      {:ok, _} = RunStore.create(build_run(sprite_name: "beta"))

      assert {:ok, runs} = RunStore.list(%{sprite_name: "alpha"})
      assert length(runs) == 1
      assert hd(runs).sprite_name == "alpha"
    end

    test "filters by status" do
      run1 = build_run(sprite_name: "s1")
      {:ok, _} = RunStore.create(run1)

      run2 = build_run(sprite_name: "s2")
      {:ok, started} = Run.start(run2)
      {:ok, _} = RunStore.create(started)

      assert {:ok, runs} = RunStore.list(%{status: :running})
      assert length(runs) == 1
      assert hd(runs).status == :running
    end

    test "sorts newest first by inserted_at" do
      run1 = build_run(sprite_name: "first")
      Process.sleep(10)
      run2 = build_run(sprite_name: "second")

      {:ok, _} = RunStore.create(run1)
      {:ok, _} = RunStore.create(run2)

      assert {:ok, [first, second]} = RunStore.list()
      assert first.sprite_name == "second"
      assert second.sprite_name == "first"
    end

    test "returns clean structs without store metadata" do
      {:ok, _} = RunStore.create(build_run())

      {:ok, [run]} = RunStore.list()
      refute Map.has_key?(run, :_key)
      refute Map.has_key?(run, :_namespace)
    end
  end

  # ── list_by_intent/1 ────────────────────────────────────────────────

  describe "list_by_intent/1" do
    test "returns runs for a specific intent" do
      {:ok, _} = RunStore.create(build_run(intent_id: "int_target"))
      {:ok, _} = RunStore.create(build_run(intent_id: "int_target"))
      {:ok, _} = RunStore.create(build_run(intent_id: "int_other"))

      assert {:ok, runs} = RunStore.list_by_intent("int_target")
      assert length(runs) == 2
      assert Enum.all?(runs, &(&1.intent_id == "int_target"))
    end
  end

  # ── list_by_sprite/1 ────────────────────────────────────────────────

  describe "list_by_sprite/1" do
    test "returns runs for a specific sprite" do
      {:ok, _} = RunStore.create(build_run(sprite_name: "target-sprite"))
      {:ok, _} = RunStore.create(build_run(sprite_name: "target-sprite"))
      {:ok, _} = RunStore.create(build_run(sprite_name: "other-sprite"))

      assert {:ok, runs} = RunStore.list_by_sprite("target-sprite")
      assert length(runs) == 2
      assert Enum.all?(runs, &(&1.sprite_name == "target-sprite"))
    end
  end

  # ── delete/1 ─────────────────────────────────────────────────────────

  describe "delete/1" do
    test "removes a run from the store" do
      run = build_run()
      {:ok, _} = RunStore.create(run)

      assert :ok = RunStore.delete(run.id)
      assert {:error, :not_found} = RunStore.get(run.id)
    end
  end
end
