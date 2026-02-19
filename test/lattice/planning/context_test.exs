defmodule Lattice.Planning.ContextTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Planning.Context

  setup do
    Context.delete("test-intent")
    :ok
  end

  describe "get/1" do
    test "returns empty context for new intent" do
      ctx = Context.get("test-intent")
      assert ctx.intent_id == "test-intent"
      assert ctx.exchanges == []
      assert ctx.notes == []
    end
  end

  describe "add_question/3" do
    test "adds a question with options" do
      ctx = Context.add_question("test-intent", "What scope?", ["small", "large"])
      assert length(ctx.exchanges) == 1
      assert hd(ctx.exchanges).question == "What scope?"
      assert hd(ctx.exchanges).options == ["small", "large"]
      assert hd(ctx.exchanges).answer == nil
    end

    test "persists across calls" do
      Context.add_question("test-intent", "Q1?", [])
      Context.add_question("test-intent", "Q2?", [])
      ctx = Context.get("test-intent")
      assert length(ctx.exchanges) == 2
    end
  end

  describe "add_answer/3" do
    test "records an answer for a question" do
      Context.add_question("test-intent", "What scope?", ["small", "large"])
      {:ok, ctx} = Context.add_answer("test-intent", 0, "large")
      assert hd(ctx.exchanges).answer == "large"
      assert hd(ctx.exchanges).answered_at != nil
    end

    test "returns error for invalid index" do
      assert {:error, :no_pending_question} = Context.add_answer("test-intent", 5, "answer")
    end
  end

  describe "all_answered?/1" do
    test "returns true when all questions answered" do
      Context.add_question("test-intent", "Q1?", [])
      {:ok, ctx} = Context.add_answer("test-intent", 0, "A1")
      assert Context.all_answered?(ctx)
    end

    test "returns false when questions pending" do
      ctx = Context.add_question("test-intent", "Q1?", [])
      refute Context.all_answered?(ctx)
    end

    test "returns true for empty exchanges" do
      ctx = Context.get("test-intent")
      assert Context.all_answered?(ctx)
    end
  end

  describe "pending_questions/1" do
    test "returns unanswered questions with indices" do
      Context.add_question("test-intent", "Q1?", [])
      Context.add_question("test-intent", "Q2?", [])
      Context.add_answer("test-intent", 0, "A1")
      ctx = Context.get("test-intent")

      pending = Context.pending_questions(ctx)
      assert length(pending) == 1
      assert {1, %{question: "Q2?"}} = hd(pending)
    end
  end

  describe "add_note/2" do
    test "adds a note to context" do
      ctx = Context.add_note("test-intent", "Important finding")
      assert ctx.notes == ["Important finding"]
    end
  end

  describe "to_markdown/1" do
    test "renders context as markdown" do
      Context.add_question("test-intent", "What scope?", ["small", "large"])
      {:ok, _} = Context.add_answer("test-intent", 0, "large")
      Context.add_note("test-intent", "A note")

      ctx = Context.get("test-intent")
      md = Context.to_markdown(ctx)

      assert md =~ "Planning Context"
      assert md =~ "What scope?"
      assert md =~ "large"
      assert md =~ "A note"
    end
  end
end
