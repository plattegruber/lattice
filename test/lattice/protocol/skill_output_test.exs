defmodule Lattice.Protocol.SkillOutputTest do
  use ExUnit.Case, async: true

  alias Lattice.Protocol.SkillOutput

  @moduletag :unit

  describe "from_map/1" do
    test "parses a valid output" do
      assert {:ok, %SkillOutput{name: "pr_url", type: "string"}} =
               SkillOutput.from_map(%{"name" => "pr_url", "type" => "string"})
    end

    test "includes description" do
      {:ok, output} =
        SkillOutput.from_map(%{
          "name" => "result",
          "type" => "map",
          "description" => "The operation result"
        })

      assert output.description == "The operation result"
    end

    test "returns error for missing name" do
      assert {:error, _} = SkillOutput.from_map(%{"type" => "string"})
    end

    test "returns error for missing type" do
      assert {:error, _} = SkillOutput.from_map(%{"name" => "result"})
    end

    test "returns error for empty map" do
      assert {:error, _} = SkillOutput.from_map(%{})
    end
  end
end
