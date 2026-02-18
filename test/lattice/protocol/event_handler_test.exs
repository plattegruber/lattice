defmodule Lattice.Protocol.EventHandlerTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Protocol.Event
  alias Lattice.Protocol.EventHandler
  alias Lattice.Protocol.Events.Artifact
  alias Lattice.Runs.Run

  setup do
    {:ok, run} = Run.new(sprite_name: "sprite-001", mode: :exec_ws)
    {:ok, running} = Run.start(run)
    {:ok, run: running}
  end

  describe "handle_event/2 with artifact event" do
    test "adds artifact to run", %{run: run} do
      artifact_data = %Artifact{
        kind: "pr",
        url: "https://github.com/org/repo/pull/1",
        metadata: %{}
      }

      event = Event.new("artifact", artifact_data, run_id: run.id)

      assert {:ok, updated_run} = EventHandler.handle_event(event, run)
      assert length(updated_run.artifacts) == 1

      [artifact] = updated_run.artifacts
      assert artifact.kind == "pr"
      assert artifact.url == "https://github.com/org/repo/pull/1"
      assert artifact.metadata == %{}
    end

    test "appends to existing artifacts", %{run: run} do
      existing = Run.add_artifact(run, %{kind: "log", url: "https://example.com/log"})

      artifact_data = %Artifact{
        kind: "pr",
        url: "https://github.com/org/repo/pull/1",
        metadata: %{}
      }

      event = Event.new("artifact", artifact_data, run_id: run.id)

      assert {:ok, updated_run} = EventHandler.handle_event(event, existing)
      assert length(updated_run.artifacts) == 2
    end

    test "preserves artifact metadata", %{run: run} do
      metadata = %{"branch" => "feature-123", "sha" => "abc123"}

      artifact_data = %Artifact{
        kind: "pr",
        url: "https://github.com/org/repo/pull/1",
        metadata: metadata
      }

      event = Event.new("artifact", artifact_data, run_id: run.id)

      assert {:ok, updated_run} = EventHandler.handle_event(event, run)
      [artifact] = updated_run.artifacts
      assert artifact.metadata == metadata
    end

    test "emits telemetry event", %{run: run} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:lattice, :run, :artifact_added]
        ])

      artifact_data = %Artifact{
        kind: "pr",
        url: "https://github.com/org/repo/pull/1",
        metadata: %{}
      }

      event = Event.new("artifact", artifact_data, run_id: run.id)

      {:ok, _updated_run} = EventHandler.handle_event(event, run)

      assert_received {[:lattice, :run, :artifact_added], ^ref, %{count: 1},
                       %{run_id: _, artifact_kind: "pr"}}
    end
  end

  describe "handle_event/2 with non-artifact event" do
    test "returns run unchanged", %{run: run} do
      event = Event.new("progress", %{message: "Working..."}, run_id: run.id)

      assert {:ok, returned_run} = EventHandler.handle_event(event, run)
      assert returned_run == run
    end
  end
end
