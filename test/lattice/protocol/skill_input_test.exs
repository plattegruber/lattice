defmodule Lattice.Protocol.SkillInputTest do
  use ExUnit.Case, async: true

  alias Lattice.Protocol.SkillInput

  @moduletag :unit

  describe "from_map/1" do
    test "parses a string input" do
      assert {:ok, %SkillInput{name: "repo", type: :string, required: true}} =
               SkillInput.from_map(%{"name" => "repo", "type" => "string"})
    end

    test "parses an integer input" do
      assert {:ok, %SkillInput{name: "count", type: :integer}} =
               SkillInput.from_map(%{"name" => "count", "type" => "integer"})
    end

    test "parses a boolean input" do
      assert {:ok, %SkillInput{name: "draft", type: :boolean}} =
               SkillInput.from_map(%{"name" => "draft", "type" => "boolean"})
    end

    test "parses a map input" do
      assert {:ok, %SkillInput{name: "config", type: :map}} =
               SkillInput.from_map(%{"name" => "config", "type" => "map"})
    end

    test "defaults required to true" do
      {:ok, input} = SkillInput.from_map(%{"name" => "x", "type" => "string"})
      assert input.required == true
    end

    test "respects required=false" do
      {:ok, input} =
        SkillInput.from_map(%{"name" => "x", "type" => "string", "required" => false})

      assert input.required == false
    end

    test "includes description and default" do
      {:ok, input} =
        SkillInput.from_map(%{
          "name" => "branch",
          "type" => "string",
          "description" => "Base branch",
          "default" => "main"
        })

      assert input.description == "Base branch"
      assert input.default == "main"
    end

    test "returns error for invalid type" do
      assert {:error, _} = SkillInput.from_map(%{"name" => "x", "type" => "float"})
    end

    test "returns error for missing name" do
      assert {:error, _} = SkillInput.from_map(%{"type" => "string"})
    end

    test "returns error for missing type" do
      assert {:error, _} = SkillInput.from_map(%{"name" => "x"})
    end
  end
end
