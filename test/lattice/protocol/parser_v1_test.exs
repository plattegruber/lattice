defmodule Lattice.Protocol.ParserV1Test do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Protocol.Event
  alias Lattice.Protocol.Parser

  alias Lattice.Protocol.Events.{
    ActionRequest,
    Artifact,
    Completed,
    EnvironmentProposal,
    Error,
    Info,
    PhaseFinished,
    PhaseStarted,
    Waiting
  }

  defp v1_line(event_type, payload) do
    json =
      Jason.encode!(%{
        "protocol_version" => "v1",
        "event_type" => event_type,
        "sprite_id" => "sprite-42",
        "work_item_id" => "issue-17",
        "timestamp" => "2026-01-15T10:30:00Z",
        "payload" => payload
      })

    "LATTICE_EVENT #{json}"
  end

  describe "v1 INFO" do
    test "parses with kind and metadata" do
      line =
        v1_line("INFO", %{
          "message" => "Running tests (75%)",
          "kind" => "progress",
          "metadata" => %{"percent" => 75, "phase" => "test"}
        })

      assert {:event, %Event{event_type: "INFO", data: %Info{} = data}} = Parser.parse_line(line)
      assert data.message == "Running tests (75%)"
      assert data.kind == "progress"
      assert data.metadata == %{"percent" => 75, "phase" => "test"}
    end

    test "parses minimal INFO (message only)" do
      line = v1_line("INFO", %{"message" => "Hello"})

      assert {:event, %Event{data: %Info{} = data}} = Parser.parse_line(line)
      assert data.message == "Hello"
      assert data.kind == nil
      assert data.metadata == %{}
    end
  end

  describe "v1 PHASE_STARTED / PHASE_FINISHED" do
    test "parses PHASE_STARTED" do
      line = v1_line("PHASE_STARTED", %{"phase" => "implement"})

      assert {:event, %Event{event_type: "PHASE_STARTED", data: %PhaseStarted{} = data}} =
               Parser.parse_line(line)

      assert data.phase == "implement"
    end

    test "parses PHASE_FINISHED with success" do
      line = v1_line("PHASE_FINISHED", %{"phase" => "test", "success" => true})

      assert {:event, %Event{event_type: "PHASE_FINISHED", data: %PhaseFinished{} = data}} =
               Parser.parse_line(line)

      assert data.phase == "test"
      assert data.success == true
    end

    test "parses PHASE_FINISHED with failure" do
      line = v1_line("PHASE_FINISHED", %{"phase" => "test", "success" => false})

      assert {:event, %Event{data: %PhaseFinished{} = data}} = Parser.parse_line(line)
      assert data.success == false
    end
  end

  describe "v1 ACTION_REQUEST" do
    test "parses non-blocking action" do
      line =
        v1_line("ACTION_REQUEST", %{
          "action" => "POST_COMMENT",
          "parameters" => %{"body" => "Done!"},
          "blocking" => false
        })

      assert {:event, %Event{data: %ActionRequest{} = data}} = Parser.parse_line(line)
      assert data.action == "POST_COMMENT"
      assert data.parameters == %{"body" => "Done!"}
      assert data.blocking == false
    end

    test "parses blocking action" do
      line =
        v1_line("ACTION_REQUEST", %{
          "action" => "OPEN_PR",
          "parameters" => %{"title" => "Fix bug", "base" => "main"},
          "blocking" => true
        })

      assert {:event, %Event{data: %ActionRequest{} = data}} = Parser.parse_line(line)
      assert data.action == "OPEN_PR"
      assert data.blocking == true
    end
  end

  describe "v1 ARTIFACT" do
    test "parses artifact declaration" do
      line =
        v1_line("ARTIFACT", %{
          "kind" => "branch",
          "ref" => "sprite/fix-cache",
          "url" => nil,
          "metadata" => %{}
        })

      assert {:event, %Event{event_type: "ARTIFACT", data: %Artifact{} = data}} =
               Parser.parse_line(line)

      assert data.kind == "branch"
    end
  end

  describe "v1 WAITING" do
    test "parses with checkpoint and expected inputs" do
      line =
        v1_line("WAITING", %{
          "reason" => "PR_REVIEW",
          "checkpoint_id" => "chk_abc123",
          "expected_inputs" => %{"approved" => "boolean"}
        })

      assert {:event, %Event{data: %Waiting{} = data}} = Parser.parse_line(line)
      assert data.reason == "PR_REVIEW"
      assert data.checkpoint_id == "chk_abc123"
      assert data.expected_inputs == %{"approved" => "boolean"}
    end
  end

  describe "v1 COMPLETED" do
    test "parses success" do
      line = v1_line("COMPLETED", %{"status" => "success", "summary" => "All done"})

      assert {:event, %Event{data: %Completed{} = data}} = Parser.parse_line(line)
      assert data.status == "success"
      assert data.summary == "All done"
    end

    test "parses failure" do
      line = v1_line("COMPLETED", %{"status" => "failure", "summary" => "Tests failed"})

      assert {:event, %Event{data: %Completed{} = data}} = Parser.parse_line(line)
      assert data.status == "failure"
    end
  end

  describe "v1 ERROR" do
    test "parses error with details" do
      line =
        v1_line("ERROR", %{
          "message" => "Build failed",
          "details" => %{"exit_code" => 1, "phase" => "test"}
        })

      assert {:event, %Event{data: %Error{} = data}} = Parser.parse_line(line)
      assert data.message == "Build failed"
      assert data.details == %{"exit_code" => 1, "phase" => "test"}
    end
  end

  describe "v1 ENVIRONMENT_PROPOSAL" do
    test "parses full proposal" do
      line =
        v1_line("ENVIRONMENT_PROPOSAL", %{
          "observed_failure" => %{
            "phase" => "bootstrap",
            "exit_code" => 127,
            "stderr_hint" => "bash: node: command not found"
          },
          "suggested_adjustment" => %{
            "type" => "runtime_install",
            "details" => %{"runtime" => "node", "version" => "20"}
          },
          "confidence" => 0.85,
          "evidence" => ["package.json present"],
          "scope" => "repo_specific"
        })

      assert {:event, %Event{data: %EnvironmentProposal{} = data}} = Parser.parse_line(line)
      assert data.observed_failure["phase"] == "bootstrap"
      assert data.suggested_adjustment["type"] == "runtime_install"
      assert data.confidence == 0.85
      assert data.evidence == ["package.json present"]
      assert data.scope == "repo_specific"
    end
  end

  describe "v1 envelope fields" do
    test "extracts sprite_id and work_item_id" do
      line = v1_line("INFO", %{"message" => "Hello"})

      assert {:event, %Event{} = event} = Parser.parse_line(line)
      assert event.sprite_id == "sprite-42"
      assert event.work_item_id == "issue-17"
      assert event.protocol_version == "v1"
    end

    test "run_id aliases work_item_id for backward compat" do
      line = v1_line("INFO", %{"message" => "Hello"})

      assert {:event, %Event{} = event} = Parser.parse_line(line)
      assert event.run_id == event.work_item_id
    end
  end

  describe "backward compatibility" do
    test "legacy artifact events still parse" do
      json =
        Jason.encode!(%{"type" => "artifact", "kind" => "pr", "url" => "https://example.com"})

      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{event_type: "artifact", data: %Artifact{}}} = Parser.parse_line(line)
    end

    test "legacy question events still parse" do
      json = Jason.encode!(%{"type" => "question", "prompt" => "Which?"})
      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{event_type: "question"}} = Parser.parse_line(line)
    end
  end
end
