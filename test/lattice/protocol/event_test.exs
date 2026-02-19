defmodule Lattice.Protocol.EventTest do
  use ExUnit.Case, async: true

  alias Lattice.Protocol.Event

  describe "new/2" do
    test "creates event with type and data" do
      data = %{message: "hello"}
      event = Event.new("progress", data)

      assert event.type == "progress"
      assert event.data == data
      assert %DateTime{} = event.timestamp
      assert event.run_id == nil
    end
  end

  describe "new/3" do
    test "creates event with custom timestamp" do
      data = %{message: "hello"}
      ts = ~U[2026-01-15 10:00:00Z]
      event = Event.new("progress", data, timestamp: ts)

      assert event.timestamp == ts
    end

    test "creates event with run_id" do
      data = %{status: "success"}
      event = Event.new("completion", data, run_id: "run_abc123")

      assert event.run_id == "run_abc123"
      assert event.type == "completion"
      assert event.data == data
    end

    test "creates event with both timestamp and run_id" do
      data = %{reason: "blocked"}
      ts = ~U[2026-02-01 12:00:00Z]
      event = Event.new("blocked", data, timestamp: ts, run_id: "run_xyz")

      assert event.timestamp == ts
      assert event.run_id == "run_xyz"
      assert event.type == "blocked"
      assert event.data == data
    end
  end
end
