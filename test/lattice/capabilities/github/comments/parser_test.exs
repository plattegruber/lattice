defmodule Lattice.Capabilities.GitHub.Comments.ParserTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Comments.Parser

  describe "extract_sentinel/1" do
    test "extracts question sentinel" do
      body = "some text\n<!-- lattice:question intent_id=int_abc -->\nfooter"

      assert {:ok, %{type: :question, attrs: %{"intent_id" => "int_abc"}}} =
               Parser.extract_sentinel(body)
    end

    test "extracts plan sentinel with version" do
      body = "<!-- lattice:plan intent_id=int_xyz version=3 -->"

      assert {:ok, %{type: :plan, attrs: attrs}} = Parser.extract_sentinel(body)
      assert attrs["intent_id"] == "int_xyz"
      assert attrs["version"] == "3"
    end

    test "extracts summary sentinel" do
      body = "## Summary\n<!-- lattice:summary intent_id=int_123 -->"

      assert {:ok, %{type: :summary, attrs: %{"intent_id" => "int_123"}}} =
               Parser.extract_sentinel(body)
    end

    test "returns :error when no sentinel present" do
      assert :error = Parser.extract_sentinel("Just a regular comment")
    end

    test "returns :error for invalid atom type" do
      assert :error = Parser.extract_sentinel("<!-- lattice:nonexistent_type_abc intent_id=x -->")
    end
  end

  describe "parse_response/1" do
    test "extracts checked checkbox items" do
      body = """
      - [x] **1.** Deploy to staging
      - [ ] **2.** Skip tests
      - [x] **3.** Notify team
      """

      assert {:ok, %{checked: [1, 3], freeform: ""}} = Parser.parse_response(body)
    end

    test "extracts freeform text" do
      body = """
      Yes, please deploy to staging and also run the smoke tests afterward.
      """

      assert {:ok, %{checked: [], freeform: freeform}} = Parser.parse_response(body)
      assert freeform =~ "please deploy to staging"
    end

    test "extracts both checked items and freeform text" do
      body = """
      - [x] **1.** Deploy to staging
      - [ ] **2.** Skip tests

      Also please run smoke tests after deploying.
      """

      assert {:ok, %{checked: [1], freeform: freeform}} = Parser.parse_response(body)
      assert freeform =~ "smoke tests"
    end

    test "returns error for empty/template-only content" do
      body = """
      ## Lattice needs your input

      **Intent:** `int_abc`

      <!-- lattice:question intent_id=int_abc -->
      _Posted by Lattice._
      """

      assert {:error, :not_a_response} = Parser.parse_response(body)
    end

    test "handles case-insensitive checkbox matching" do
      body = "- [X] **1.** Option one"

      assert {:ok, %{checked: [1]}} = Parser.parse_response(body)
    end
  end

  describe "parse_comment/1" do
    test "combines sentinel and response extraction" do
      body = """
      - [x] **1.** Deploy to staging
      - [ ] **2.** Skip tests

      Sounds good, go ahead.

      <!-- lattice:question intent_id=int_abc -->
      _Posted by Lattice._
      """

      assert {:ok, result} = Parser.parse_comment(body)
      assert result.intent_id == "int_abc"
      assert result.type == :question
      assert 1 in result.response.checked
      assert result.response.freeform =~ "Sounds good"
    end

    test "returns error for non-lattice comment" do
      assert {:error, :not_a_lattice_comment} = Parser.parse_comment("Just a regular comment")
    end

    test "returns error when sentinel present but no response content" do
      body = """
      ## Lattice needs your input
      <!-- lattice:question intent_id=int_abc -->
      _Posted by Lattice._
      """

      assert {:error, :not_a_response} = Parser.parse_comment(body)
    end
  end

  describe "round-trip: question → response" do
    test "posted question can be parsed after user edits checkboxes" do
      alias Lattice.Capabilities.GitHub.Comments
      alias Lattice.Intents.Intent

      now = DateTime.utc_now()

      intent = %Intent{
        id: "int_round_trip",
        kind: :action,
        state: :waiting_for_input,
        source: %{type: :sprite, id: "sprite-001"},
        summary: "Deploy prod",
        payload: %{},
        classification: :controlled,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }

      original =
        Comments.question_comment(intent, [
          %{text: "Deploy to production?"},
          %{text: "Run smoke tests?"}
        ])

      # Simulate user checking item 1 and adding freeform
      user_edited =
        original
        |> String.replace("- [ ] **1.**", "- [x] **1.**")
        |> Kernel.<>("\n\nYes, deploy now please.")

      assert {:ok, %{type: :question, attrs: %{"intent_id" => "int_round_trip"}}} =
               Parser.extract_sentinel(user_edited)

      assert {:ok, %{checked: [1], freeform: freeform}} = Parser.parse_response(user_edited)
      assert freeform =~ "deploy now please"
    end
  end
end
