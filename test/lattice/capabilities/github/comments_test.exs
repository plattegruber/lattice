defmodule Lattice.Capabilities.GitHub.CommentsTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Comments
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Plan
  alias Lattice.Intents.Plan.Step

  defp build_intent(overrides \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %Intent{
        id: "int_test123",
        kind: :action,
        state: :running,
        source: %{type: :sprite, id: "sprite-001"},
        summary: "Deploy staging",
        payload: %{},
        classification: :controlled,
        metadata: %{governance_issue: 42},
        inserted_at: now,
        updated_at: now
      },
      overrides
    )
  end

  describe "question_comment/2" do
    test "renders questions with checkboxes and sentinel" do
      intent = build_intent(%{pending_question: %{text: "Which environment?"}})

      questions = [
        %{text: "Deploy to staging?"},
        %{text: "Run integration tests?"}
      ]

      result = Comments.question_comment(intent, questions)

      assert result =~ "Lattice needs your input"
      assert result =~ "`int_test123`"
      assert result =~ "Deploy staging"
      assert result =~ "- [ ] **1.** Deploy to staging?"
      assert result =~ "- [ ] **2.** Run integration tests?"
      assert result =~ "<!-- lattice:question intent_id=int_test123 -->"
      assert result =~ "How to respond"
    end

    test "handles a single question map" do
      intent = build_intent()
      result = Comments.question_comment(intent, %{text: "Proceed?"})

      assert result =~ "- [ ] **1.** Proceed?"
    end
  end

  describe "plan_comment/2" do
    test "renders plan with rendered_markdown" do
      intent = build_intent()

      plan = %Plan{
        title: "Deploy Plan",
        steps: [],
        source: :agent,
        version: 2,
        rendered_markdown: "## Deploy Plan\n\n1. [ ] Build\n2. [ ] Deploy"
      }

      result = Comments.plan_comment(intent, plan)

      assert result =~ "Proposed Execution Plan"
      assert result =~ "`int_test123`"
      assert result =~ "## Deploy Plan"
      assert result =~ "1. [ ] Build"
      assert result =~ "intent-approved"
      assert result =~ "<!-- lattice:plan intent_id=int_test123 version=2 -->"
    end

    test "falls back to step rendering when no rendered_markdown" do
      intent = build_intent()

      plan = %Plan{
        title: "Test Plan",
        steps: [
          %Step{id: "s1", description: "Run tests", skill: "test_runner", status: :pending},
          %Step{id: "s2", description: "Deploy", skill: nil, status: :completed}
        ],
        source: :agent,
        version: 1,
        rendered_markdown: ""
      }

      result = Comments.plan_comment(intent, plan)

      assert result =~ "1. [ ] Run tests `test_runner`"
      assert result =~ "2. [x] Deploy"
    end
  end

  describe "summary_comment/2" do
    test "renders success summary" do
      intent = build_intent()
      result_data = %{status: :success, duration_ms: 1500, output: "Deployed successfully"}

      result = Comments.summary_comment(intent, result_data)

      assert result =~ "Execution Completed"
      assert result =~ "`int_test123`"
      assert result =~ "1.5s"
      assert result =~ "Deployed successfully"
      assert result =~ "<!-- lattice:summary intent_id=int_test123 -->"
    end

    test "renders failure summary with error" do
      intent = build_intent()
      result_data = %{status: :failure, duration_ms: 200, error: "Connection refused"}

      result = Comments.summary_comment(intent, result_data)

      assert result =~ "Execution Failed"
      assert result =~ "200ms"
      assert result =~ "Connection refused"
    end

    test "renders artifacts when present" do
      intent =
        build_intent(%{
          metadata: %{
            governance_issue: 42,
            artifacts: [
              %{label: "PR #10", url: "https://github.com/org/repo/pull/10"},
              %{type: "branch", label: "feat/deploy"}
            ]
          }
        })

      result_data = %{status: :success}
      result = Comments.summary_comment(intent, result_data)

      assert result =~ "Artifacts"
      assert result =~ "[PR #10](https://github.com/org/repo/pull/10)"
      assert result =~ "- feat/deploy"
    end

    test "handles no duration" do
      intent = build_intent()
      result = Comments.summary_comment(intent, %{status: :success})

      assert result =~ "N/A"
    end
  end

  describe "progress_comment/2" do
    test "renders progress update" do
      intent = build_intent()
      update = %{current_step: 2, total_steps: 5, message: "Running integration tests..."}

      result = Comments.progress_comment(intent, update)

      assert result =~ "Progress Update"
      assert result =~ "2 of 5"
      assert result =~ "Running integration tests..."
      assert result =~ "<!-- lattice:progress intent_id=int_test123 -->"
    end
  end
end
