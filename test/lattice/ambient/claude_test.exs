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
end
