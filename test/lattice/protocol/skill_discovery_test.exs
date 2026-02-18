defmodule Lattice.Protocol.SkillDiscoveryTest do
  use ExUnit.Case, async: true

  alias Lattice.Protocol.SkillDiscovery
  alias Lattice.Protocol.SkillManifest

  @moduletag :unit

  describe "parse_skill_manifests/1" do
    test "parses a single skill manifest" do
      json = Jason.encode!(%{"name" => "deploy", "description" => "Deploy app"})

      skills = SkillDiscovery.parse_skill_manifests(json)

      assert [%SkillManifest{name: "deploy", description: "Deploy app"}] = skills
    end

    test "parses multiple concatenated JSON objects" do
      json =
        Jason.encode!(%{"name" => "deploy"}) <>
          Jason.encode!(%{"name" => "test"})

      skills = SkillDiscovery.parse_skill_manifests(json)

      assert length(skills) == 2
      names = Enum.map(skills, & &1.name)
      assert "deploy" in names
      assert "test" in names
    end

    test "parses newline-separated JSON objects" do
      json =
        Jason.encode!(%{"name" => "deploy"}) <>
          "\n" <>
          Jason.encode!(%{"name" => "test"})

      skills = SkillDiscovery.parse_skill_manifests(json)

      assert length(skills) == 2
    end

    test "skips invalid JSON" do
      json = "not valid json"

      skills = SkillDiscovery.parse_skill_manifests(json)

      assert skills == []
    end

    test "skips manifests with missing name" do
      json = Jason.encode!(%{"description" => "no name"})

      skills = SkillDiscovery.parse_skill_manifests(json)

      assert skills == []
    end

    test "parses manifest with full inputs and outputs" do
      json =
        Jason.encode!(%{
          "name" => "open_pr",
          "description" => "Open a pull request",
          "inputs" => [
            %{"name" => "repo", "type" => "string", "required" => true}
          ],
          "outputs" => [
            %{"name" => "pr_url", "type" => "string"}
          ],
          "permissions" => ["github:write"],
          "produces_events" => true
        })

      [skill] = SkillDiscovery.parse_skill_manifests(json)

      assert skill.name == "open_pr"
      assert length(skill.inputs) == 1
      assert length(skill.outputs) == 1
      assert skill.permissions == ["github:write"]
      assert skill.produces_events == true
    end

    test "handles empty input" do
      assert [] = SkillDiscovery.parse_skill_manifests("")
    end

    test "handles whitespace-only input" do
      assert [] = SkillDiscovery.parse_skill_manifests("   \n  ")
    end
  end
end
