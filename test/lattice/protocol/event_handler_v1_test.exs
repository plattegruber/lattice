defmodule Lattice.Protocol.EventHandlerV1Test do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Protocol.Event
  alias Lattice.Protocol.EventHandler
  alias Lattice.Protocol.Events.ActionRequest
  alias Lattice.Protocol.Events.Completed
  alias Lattice.Protocol.Events.EnvironmentProposal
  alias Lattice.Protocol.Events.Error, as: ErrorEvent
  alias Lattice.Protocol.Events.Info
  alias Lattice.Protocol.Events.PhaseFinished
  alias Lattice.Protocol.Events.PhaseStarted
  alias Lattice.Protocol.Events.Waiting
  alias Lattice.Runs.Run

  setup do
    {:ok, run} = Run.new(sprite_name: "sprite-42", mode: :exec_ws)
    {:ok, running} = Run.start(run)
    {:ok, run: running}
  end

  defp v1_event(type, data, opts \\ []) do
    Event.new(type, data,
      sprite_id: "sprite-42",
      work_item_id: Keyword.get(opts, :work_item_id, "issue-17")
    )
  end

  describe "WAITING" do
    test "transitions run to :waiting with checkpoint info", %{run: run} do
      waiting = %Waiting{
        reason: "PR_REVIEW",
        checkpoint_id: "chk_abc123",
        expected_inputs: %{"approved" => "boolean"}
      }

      event = v1_event("WAITING", waiting)
      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :waiting
      assert updated.checkpoint_id == "chk_abc123"
      assert updated.expected_inputs == %{"approved" => "boolean"}
      assert updated.blocked_reason == "PR_REVIEW"
    end

    test "emits telemetry", %{run: run} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:lattice, :run, :waiting]])

      waiting = %Waiting{
        reason: "PR_REVIEW",
        checkpoint_id: "chk_abc123",
        expected_inputs: %{}
      }

      event = v1_event("WAITING", waiting)
      {:ok, _} = EventHandler.handle_event(event, run)

      assert_received {[:lattice, :run, :waiting], ^ref, %{count: 1},
                       %{run_id: _, checkpoint_id: "chk_abc123"}}
    end
  end

  describe "COMPLETED" do
    test "success transitions to :succeeded", %{run: run} do
      completed = %Completed{status: "success", summary: "All done"}
      event = v1_event("COMPLETED", completed)

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :succeeded
    end

    test "failure transitions to :failed", %{run: run} do
      completed = %Completed{status: "failure", summary: "Tests broken"}
      event = v1_event("COMPLETED", completed)

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :failed
      assert updated.error == "Tests broken"
    end
  end

  describe "ERROR" do
    test "transitions to :failed with error message", %{run: run} do
      error = %ErrorEvent{message: "Build exploded", details: %{"exit_code" => 1}}
      event = v1_event("ERROR", error)

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :failed
      assert updated.error == "Build exploded"
    end
  end

  describe "ACTION_REQUEST" do
    test "non-blocking does not change run state", %{run: run} do
      action = %ActionRequest{
        action: "POST_COMMENT",
        parameters: %{"body" => "Done!"},
        blocking: false
      }

      event = v1_event("ACTION_REQUEST", action)
      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :running
    end

    test "emits telemetry with action info", %{run: run} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:lattice, :run, :action_requested]])

      action = %ActionRequest{action: "OPEN_PR", parameters: %{}, blocking: true}
      event = v1_event("ACTION_REQUEST", action)
      {:ok, _} = EventHandler.handle_event(event, run)

      assert_received {[:lattice, :run, :action_requested], ^ref, %{count: 1},
                       %{action: "OPEN_PR", blocking: true}}
    end
  end

  describe "PHASE_STARTED / PHASE_FINISHED" do
    test "PHASE_STARTED does not change run state", %{run: run} do
      phase = %PhaseStarted{phase: "implement"}
      event = v1_event("PHASE_STARTED", phase)

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :running
    end

    test "PHASE_FINISHED does not change run state", %{run: run} do
      phase = %PhaseFinished{phase: "test", success: true}
      event = v1_event("PHASE_FINISHED", phase)

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :running
    end

    test "PHASE_STARTED emits telemetry", %{run: run} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:lattice, :run, :phase_started]])

      phase = %PhaseStarted{phase: "test"}
      event = v1_event("PHASE_STARTED", phase)
      {:ok, _} = EventHandler.handle_event(event, run)

      assert_received {[:lattice, :run, :phase_started], ^ref, %{count: 1}, %{phase: "test"}}
    end
  end

  describe "INFO" do
    test "does not change run state", %{run: run} do
      info = %Info{message: "Hello", kind: "note", metadata: %{}}
      event = v1_event("INFO", info)

      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :running
    end
  end

  describe "ENVIRONMENT_PROPOSAL" do
    test "does not change run state", %{run: run} do
      proposal = %EnvironmentProposal{
        observed_failure: %{"phase" => "bootstrap", "exit_code" => 127},
        suggested_adjustment: %{"type" => "runtime_install"},
        confidence: 0.85,
        evidence: ["package.json present"],
        scope: "repo_specific"
      }

      event = v1_event("ENVIRONMENT_PROPOSAL", proposal)
      assert {:ok, updated} = EventHandler.handle_event(event, run)
      assert updated.status == :running
    end

    test "emits telemetry", %{run: run} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:lattice, :run, :environment_proposal]])

      proposal = %EnvironmentProposal{
        observed_failure: %{},
        suggested_adjustment: %{"type" => "add_system_package"},
        confidence: 0.7,
        evidence: [],
        scope: "global_candidate"
      }

      event = v1_event("ENVIRONMENT_PROPOSAL", proposal)
      {:ok, _} = EventHandler.handle_event(event, run)

      assert_received {[:lattice, :run, :environment_proposal], ^ref, %{count: 1},
                       %{scope: "global_candidate", confidence: 0.7}}
    end
  end

  describe "Run :waiting lifecycle" do
    test "waiting run can be resumed", %{run: run} do
      waiting = %Waiting{reason: "test", checkpoint_id: "chk_1", expected_inputs: %{}}
      event = v1_event("WAITING", waiting)
      {:ok, waiting_run} = EventHandler.handle_event(event, run)

      assert waiting_run.status == :waiting
      assert {:ok, resumed} = Run.resume(waiting_run, %{"answer" => "yes"})
      assert resumed.status == :running
    end

    test "waiting run can be failed", %{run: run} do
      waiting = %Waiting{reason: "test", checkpoint_id: "chk_1", expected_inputs: %{}}
      event = v1_event("WAITING", waiting)
      {:ok, waiting_run} = EventHandler.handle_event(event, run)

      assert {:ok, failed} = Run.fail(waiting_run, %{error: "timed out"})
      assert failed.status == :failed
    end

    test "waiting run can be canceled", %{run: run} do
      waiting = %Waiting{reason: "test", checkpoint_id: "chk_1", expected_inputs: %{}}
      event = v1_event("WAITING", waiting)
      {:ok, waiting_run} = EventHandler.handle_event(event, run)

      assert {:ok, canceled} = Run.cancel(waiting_run)
      assert canceled.status == :canceled
    end
  end
end
