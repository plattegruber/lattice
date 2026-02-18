defmodule Lattice.Protocol.EventHandlerAssumptionTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Protocol.Event
  alias Lattice.Protocol.EventHandler
  alias Lattice.Protocol.Events.Assumption
  alias Lattice.Runs.Run

  setup do
    {:ok, run} = Run.new(sprite_name: "sprite-001", mode: :exec_ws)
    {:ok, running} = Run.start(run)
    {:ok, run: running}
  end

  describe "handle_event/2 with assumption event" do
    test "adds assumptions from a single-file event", %{run: run} do
      assumption_data = %Assumption{
        files: [
          %{path: "lib/foo.ex", lines: [1, 50], note: "stable module"}
        ]
      }

      event = Event.new("assumption", assumption_data, run_id: run.id)

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert length(updated.assumptions) == 1

      [assumption] = updated.assumptions
      assert assumption.path == "lib/foo.ex"
      assert assumption.lines == [1, 50]
      assert assumption.note == "stable module"
      assert %DateTime{} = assumption.timestamp
    end

    test "adds assumptions from a multi-file event", %{run: run} do
      assumption_data = %Assumption{
        files: [
          %{path: "lib/a.ex", lines: [1, 10], note: "first file"},
          %{path: "lib/b.ex", lines: [20, 30], note: "second file"},
          %{path: "lib/c.ex", lines: [], note: "third file"}
        ]
      }

      event = Event.new("assumption", assumption_data, run_id: run.id)

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert length(updated.assumptions) == 3

      paths = Enum.map(updated.assumptions, & &1.path)
      assert paths == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    end

    test "accumulates assumptions across multiple events", %{run: run} do
      event1 =
        Event.new("assumption", %Assumption{
          files: [%{path: "lib/first.ex", lines: [], note: "first"}]
        })

      event2 =
        Event.new("assumption", %Assumption{
          files: [%{path: "lib/second.ex", lines: [], note: "second"}]
        })

      assert {:ok, after_first} = EventHandler.handle_event(event1, run)
      assert {:ok, after_second} = EventHandler.handle_event(event2, after_first)

      assert length(after_second.assumptions) == 2
      assert Enum.at(after_second.assumptions, 0).path == "lib/first.ex"
      assert Enum.at(after_second.assumptions, 1).path == "lib/second.ex"
    end

    test "does not modify artifacts", %{run: run} do
      event =
        Event.new("assumption", %Assumption{
          files: [%{path: "lib/foo.ex", lines: [], note: "test"}]
        })

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.artifacts == run.artifacts
    end
  end
end
