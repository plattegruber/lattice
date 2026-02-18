defmodule Lattice.Protocol.SkillManifestTest do
  use ExUnit.Case, async: true

  alias Lattice.Protocol.SkillInput
  alias Lattice.Protocol.SkillManifest
  alias Lattice.Protocol.SkillOutput

  @moduletag :unit

  describe "from_map/1" do
    test "parses a minimal manifest" do
      map = %{"name" => "deploy"}

      assert {:ok, %SkillManifest{name: "deploy"}} = SkillManifest.from_map(map)
    end

    test "parses a full manifest" do
      map = %{
        "name" => "open_pr",
        "description" => "Opens a pull request",
        "inputs" => [
          %{
            "name" => "repo",
            "type" => "string",
            "required" => true,
            "description" => "Target repository"
          },
          %{
            "name" => "draft",
            "type" => "boolean",
            "required" => false,
            "default" => false
          }
        ],
        "outputs" => [
          %{
            "name" => "pr_url",
            "type" => "string",
            "description" => "URL of the created PR"
          }
        ],
        "permissions" => ["github:write", "github:read"],
        "produces_events" => true
      }

      assert {:ok, manifest} = SkillManifest.from_map(map)
      assert manifest.name == "open_pr"
      assert manifest.description == "Opens a pull request"
      assert length(manifest.inputs) == 2
      assert length(manifest.outputs) == 1
      assert manifest.permissions == ["github:write", "github:read"]
      assert manifest.produces_events == true

      [repo_input, draft_input] = manifest.inputs
      assert %SkillInput{name: "repo", type: :string, required: true} = repo_input

      assert %SkillInput{name: "draft", type: :boolean, required: false, default: false} =
               draft_input

      [pr_output] = manifest.outputs
      assert %SkillOutput{name: "pr_url", type: "string"} = pr_output
    end

    test "returns error for missing name" do
      assert {:error, _} = SkillManifest.from_map(%{})
    end

    test "returns error for empty name" do
      assert {:error, _} = SkillManifest.from_map(%{"name" => ""})
    end

    test "returns error for invalid input type" do
      map = %{
        "name" => "test",
        "inputs" => [%{"name" => "x", "type" => "invalid_type"}]
      }

      assert {:error, _} = SkillManifest.from_map(map)
    end

    test "defaults produces_events to false" do
      {:ok, manifest} = SkillManifest.from_map(%{"name" => "simple"})

      assert manifest.produces_events == false
    end

    test "defaults inputs and outputs to empty lists" do
      {:ok, manifest} = SkillManifest.from_map(%{"name" => "simple"})

      assert manifest.inputs == []
      assert manifest.outputs == []
    end

    test "defaults permissions to empty list" do
      {:ok, manifest} = SkillManifest.from_map(%{"name" => "simple"})

      assert manifest.permissions == []
    end
  end

  describe "validate_inputs/2" do
    test "returns :ok for valid inputs" do
      {:ok, manifest} =
        SkillManifest.from_map(%{
          "name" => "test",
          "inputs" => [
            %{"name" => "repo", "type" => "string", "required" => true},
            %{"name" => "count", "type" => "integer", "required" => true}
          ]
        })

      assert :ok =
               SkillManifest.validate_inputs(manifest, %{"repo" => "owner/repo", "count" => 5})
    end

    test "returns errors for missing required inputs" do
      {:ok, manifest} =
        SkillManifest.from_map(%{
          "name" => "test",
          "inputs" => [
            %{"name" => "repo", "type" => "string", "required" => true},
            %{"name" => "branch", "type" => "string", "required" => true}
          ]
        })

      assert {:error, errors} = SkillManifest.validate_inputs(manifest, %{})
      assert {"repo", "is required"} in errors
      assert {"branch", "is required"} in errors
    end

    test "allows missing optional inputs" do
      {:ok, manifest} =
        SkillManifest.from_map(%{
          "name" => "test",
          "inputs" => [
            %{"name" => "draft", "type" => "boolean", "required" => false}
          ]
        })

      assert :ok = SkillManifest.validate_inputs(manifest, %{})
    end

    test "returns errors for type mismatches" do
      {:ok, manifest} =
        SkillManifest.from_map(%{
          "name" => "test",
          "inputs" => [
            %{"name" => "count", "type" => "integer", "required" => true},
            %{"name" => "enabled", "type" => "boolean", "required" => true},
            %{"name" => "config", "type" => "map", "required" => true}
          ]
        })

      assert {:error, errors} =
               SkillManifest.validate_inputs(manifest, %{
                 "count" => "not_an_int",
                 "enabled" => "not_a_bool",
                 "config" => "not_a_map"
               })

      assert length(errors) == 3
    end

    test "validates string type" do
      {:ok, manifest} =
        SkillManifest.from_map(%{
          "name" => "test",
          "inputs" => [%{"name" => "name", "type" => "string", "required" => true}]
        })

      assert :ok = SkillManifest.validate_inputs(manifest, %{"name" => "hello"})
      assert {:error, _} = SkillManifest.validate_inputs(manifest, %{"name" => 123})
    end

    test "validates map type" do
      {:ok, manifest} =
        SkillManifest.from_map(%{
          "name" => "test",
          "inputs" => [%{"name" => "config", "type" => "map", "required" => true}]
        })

      assert :ok = SkillManifest.validate_inputs(manifest, %{"config" => %{"key" => "val"}})
      assert {:error, _} = SkillManifest.validate_inputs(manifest, %{"config" => "not_a_map"})
    end
  end
end
