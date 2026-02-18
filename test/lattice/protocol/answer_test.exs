defmodule Lattice.Protocol.AnswerTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Protocol.Answer

  describe "new/1" do
    test "builds an answer from atom-keyed map" do
      answer =
        Answer.new(%{
          question_prompt: "Which branch?",
          selected_choice: "main",
          free_text: nil,
          answered_by: "alice"
        })

      assert answer.question_prompt == "Which branch?"
      assert answer.selected_choice == "main"
      assert answer.free_text == nil
      assert answer.answered_by == "alice"
      assert %DateTime{} = answer.answered_at
    end

    test "builds an answer from string-keyed map" do
      answer =
        Answer.new(%{
          "question_prompt" => "Deploy target?",
          "selected_choice" => "staging",
          "free_text" => "deploy to staging first",
          "answered_by" => "bob"
        })

      assert answer.question_prompt == "Deploy target?"
      assert answer.selected_choice == "staging"
      assert answer.free_text == "deploy to staging first"
      assert answer.answered_by == "bob"
    end

    test "defaults answered_by to operator" do
      answer = Answer.new(%{question_prompt: "Continue?"})

      assert answer.answered_by == "operator"
    end

    test "sets answered_at to current time" do
      before = DateTime.utc_now()
      answer = Answer.new(%{question_prompt: "?"})
      after_time = DateTime.utc_now()

      assert DateTime.compare(answer.answered_at, before) in [:gt, :eq]
      assert DateTime.compare(answer.answered_at, after_time) in [:lt, :eq]
    end
  end
end
