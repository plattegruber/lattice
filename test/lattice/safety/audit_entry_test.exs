defmodule Lattice.Safety.AuditEntryTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Safety.AuditEntry

  describe "new/6" do
    test "creates an audit entry with required fields" do
      assert {:ok, entry} = AuditEntry.new(:sprites, :wake, :controlled, :ok, :human)

      assert entry.capability == :sprites
      assert entry.operation == :wake
      assert entry.classification == :controlled
      assert entry.result == :ok
      assert entry.actor == :human
      assert entry.args == []
      assert %DateTime{} = entry.timestamp
    end

    test "accepts optional args" do
      assert {:ok, entry} =
               AuditEntry.new(:sprites, :wake, :controlled, :ok, :human, args: ["sprite-001"])

      assert entry.args == ["sprite-001"]
    end

    test "accepts optional timestamp" do
      ts = ~U[2026-02-16 12:00:00Z]

      assert {:ok, entry} =
               AuditEntry.new(:sprites, :wake, :controlled, :ok, :system, timestamp: ts)

      assert entry.timestamp == ts
    end

    test "accepts :system actor" do
      assert {:ok, entry} = AuditEntry.new(:sprites, :list_sprites, :safe, :ok, :system)
      assert entry.actor == :system
    end

    test "accepts :scheduled actor" do
      assert {:ok, entry} = AuditEntry.new(:sprites, :list_sprites, :safe, :ok, :scheduled)
      assert entry.actor == :scheduled
    end

    test "accepts error results" do
      assert {:ok, entry} =
               AuditEntry.new(:sprites, :wake, :controlled, {:error, :timeout}, :system)

      assert entry.result == {:error, :timeout}
    end

    test "accepts :denied result" do
      assert {:ok, entry} = AuditEntry.new(:fly, :deploy, :dangerous, :denied, :human)
      assert entry.result == :denied
    end

    test "rejects invalid actor" do
      assert {:error, {:invalid_actor, :unknown}} =
               AuditEntry.new(:sprites, :wake, :controlled, :ok, :unknown)
    end
  end

  describe "valid_actors/0" do
    test "returns all valid actor types" do
      assert AuditEntry.valid_actors() == [:system, :human, :scheduled]
    end
  end

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(AuditEntry, %{capability: :sprites})
      end
    end
  end
end
