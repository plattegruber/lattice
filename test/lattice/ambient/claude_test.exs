defmodule Lattice.Ambient.ClaudeTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Ambient.Claude

  describe "classify/2 without API key" do
    test "returns :ignore when no API key is configured" do
      # Default test env has no ANTHROPIC_API_KEY
      assert {:ok, :ignore, nil} = Claude.classify(%{type: :issue_comment, body: "Hello"})
    end
  end

  describe "parse_decision/1" do
    test "parses delegate decision" do
      assert {:ok, :delegate, nil} = Claude.parse_decision("DECISION: delegate")
    end

    test "parses respond decision with text" do
      text = "DECISION: respond\nHere is my response."
      assert {:ok, :respond, "Here is my response."} = Claude.parse_decision(text)
    end

    test "parses react decision" do
      assert {:ok, :react, nil} = Claude.parse_decision("DECISION: react")
    end

    test "parses ignore decision" do
      assert {:ok, :ignore, nil} = Claude.parse_decision("DECISION: ignore")
    end

    test "defaults to ignore for unrecognized format" do
      assert {:ok, :ignore, nil} = Claude.parse_decision("I'm not sure what to do")
    end

    test "delegate takes priority over respond when both present" do
      # delegate is checked first in the cond
      text = "DECISION: delegate\nDECISION: respond\nsome text"
      assert {:ok, :delegate, nil} = Claude.parse_decision(text)
    end
  end
end
