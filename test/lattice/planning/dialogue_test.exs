defmodule Lattice.Planning.DialogueTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Planning.Context
  alias Lattice.Planning.Dialogue

  setup do
    Context.delete("test-dialogue")
    :ok
  end

  defp new_intent(opts \\ []) do
    summary = Keyword.get(opts, :summary, "Fix the login bug")
    payload = Keyword.get(opts, :payload, %{"issue_url" => "https://example.com/1"})
    kind = Keyword.get(opts, :kind, :action)
    resources = Keyword.get(opts, :affected_resources, ["code"])
    effects = Keyword.get(opts, :expected_side_effects, ["none"])

    {:ok, intent} =
      Intent.new_action(%{type: :system, id: "sys"},
        summary: summary,
        payload: payload,
        affected_resources: resources,
        expected_side_effects: effects
      )

    %{intent | kind: kind}
  end

  describe "analyze/1" do
    test "generates scope question for issue_triage without scope" do
      intent = new_intent(kind: :issue_triage)
      questions = Dialogue.analyze(intent)

      scope_q = Enum.find(questions, &(&1.category == :scope))
      assert scope_q != nil
      assert scope_q.text =~ "scope"
    end

    test "skips scope question when scope is provided" do
      intent =
        new_intent(
          kind: :issue_triage,
          payload: %{"scope" => "single_file", "issue_url" => "https://example.com/1"}
        )

      questions = Dialogue.analyze(intent)
      refute Enum.any?(questions, &(&1.category == :scope))
    end

    test "generates approach question for issue_triage" do
      intent = new_intent(kind: :issue_triage, summary: "Refactor auth module")
      questions = Dialogue.analyze(intent)

      approach_q = Enum.find(questions, &(&1.category == :approach))
      assert approach_q != nil
      assert approach_q.options != []
    end

    test "generates risk question for intents with side effects" do
      intent =
        new_intent(
          payload: %{
            "capability" => "fly",
            "operation" => "deploy",
            "environment" => "staging"
          },
          affected_resources: ["fly"],
          expected_side_effects: ["deploy"]
        )

      questions = Dialogue.analyze(intent)
      risk_q = Enum.find(questions, &(&1.category == :risk))
      assert risk_q != nil
    end
  end

  describe "needs_clarification?/1" do
    test "returns true for issue_triage without context" do
      intent = new_intent(kind: :issue_triage)
      assert Dialogue.needs_clarification?(intent)
    end

    test "returns false when all info provided" do
      intent =
        new_intent(
          payload: %{
            "scope" => "single_file",
            "approach" => "quick_fix",
            "risk_tolerance" => "low"
          }
        )

      refute Dialogue.needs_clarification?(intent)
    end
  end

  describe "ask_questions/2" do
    test "adds questions to intent context" do
      questions = [
        %{category: :scope, text: "What scope?", options: ["small", "large"]},
        %{category: :approach, text: "What approach?", options: ["fix", "refactor"]}
      ]

      ctx = Dialogue.ask_questions("test-dialogue", questions)
      assert [_, _] = ctx.exchanges
    end
  end

  describe "generate_plan/2" do
    test "generates plan when all questions answered" do
      intent = new_intent(kind: :issue_triage, summary: "Fix the login bug")

      Context.add_question("test-dialogue", "What approach?", ["fix", "refactor"])
      {:ok, _} = Context.add_answer("test-dialogue", 0, "Quick fix (minimal changes)")
      ctx = Context.get("test-dialogue")

      assert {:ok, plan} = Dialogue.generate_plan(intent, ctx)
      assert plan.title =~ "Fix the login bug"
      assert plan.steps != []
      assert plan.source == :system
    end

    test "returns error when questions unanswered" do
      intent = new_intent(summary: "Fix bug")

      Context.add_question("test-dialogue", "What scope?", [])
      ctx = Context.get("test-dialogue")

      assert {:error, :unanswered_questions} = Dialogue.generate_plan(intent, ctx)
    end
  end
end
