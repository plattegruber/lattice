defmodule Lattice.Protocol.TaskPayloadTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Protocol.TaskPayload

  # ── new/1 ─────────────────────────────────────────────────────────

  describe "new/1" do
    test "creates payload with atom keys" do
      assert {:ok, %TaskPayload{} = tp} =
               TaskPayload.new(%{
                 run_id: "run_abc123",
                 goal: "Add a README file"
               })

      assert tp.run_id == "run_abc123"
      assert tp.goal == "Add a README file"
      assert tp.constraints == %{}
      assert tp.answers == %{}
      assert tp.env == %{}
      assert tp.repo == nil
      assert tp.skill == nil
      assert tp.acceptance == nil
    end

    test "creates payload with string keys" do
      assert {:ok, %TaskPayload{} = tp} =
               TaskPayload.new(%{
                 "run_id" => "run_xyz789",
                 "goal" => "Fix the bug",
                 "repo" => "plattegruber/webapp",
                 "skill" => "open_pr_trivial_change"
               })

      assert tp.run_id == "run_xyz789"
      assert tp.goal == "Fix the bug"
      assert tp.repo == "plattegruber/webapp"
      assert tp.skill == "open_pr_trivial_change"
    end

    test "creates payload with all fields" do
      assert {:ok, %TaskPayload{} = tp} =
               TaskPayload.new(%{
                 run_id: "run_full",
                 goal: "Implement feature X",
                 repo: "org/repo",
                 skill: "code_change",
                 constraints: %{base_branch: "develop"},
                 acceptance: "Tests pass",
                 answers: %{"key" => "value"},
                 env: %{"API_KEY" => "secret"}
               })

      assert tp.run_id == "run_full"
      assert tp.goal == "Implement feature X"
      assert tp.repo == "org/repo"
      assert tp.skill == "code_change"
      assert tp.constraints == %{base_branch: "develop"}
      assert tp.acceptance == "Tests pass"
      assert tp.answers == %{"key" => "value"}
      assert tp.env == %{"API_KEY" => "secret"}
    end

    test "creates payload from keyword list" do
      assert {:ok, %TaskPayload{} = tp} =
               TaskPayload.new(run_id: "run_kw", goal: "Do something")

      assert tp.run_id == "run_kw"
      assert tp.goal == "Do something"
    end

    test "returns error when run_id is missing" do
      assert {:error, [:run_id]} = TaskPayload.new(%{goal: "Do something"})
    end

    test "returns error when goal is missing" do
      assert {:error, [:goal]} = TaskPayload.new(%{run_id: "run_123"})
    end

    test "returns error when both required fields are missing" do
      assert {:error, missing} = TaskPayload.new(%{})
      assert :run_id in missing
      assert :goal in missing
    end

    test "returns error when run_id is empty string" do
      assert {:error, [:run_id]} = TaskPayload.new(%{run_id: "", goal: "Do something"})
    end

    test "returns error when goal is empty string" do
      assert {:error, [:goal]} = TaskPayload.new(%{run_id: "run_123", goal: ""})
    end

    test "defaults maps to empty when nil" do
      assert {:ok, %TaskPayload{} = tp} =
               TaskPayload.new(%{
                 run_id: "run_defaults",
                 goal: "Test defaults",
                 constraints: nil,
                 answers: nil,
                 env: nil
               })

      assert tp.constraints == %{}
      assert tp.answers == %{}
      assert tp.env == %{}
    end
  end

  # ── validate/1 ────────────────────────────────────────────────────

  describe "validate/1" do
    test "returns ok for valid payload" do
      {:ok, tp} = TaskPayload.new(%{run_id: "run_valid", goal: "Valid goal"})

      assert {:ok, ^tp} = TaskPayload.validate(tp)
    end

    test "returns error for payload with nil run_id" do
      # Construct an invalid struct directly by bypassing new/1
      tp = %TaskPayload{run_id: nil, goal: "Has goal"}

      assert {:error, [:run_id]} = TaskPayload.validate(tp)
    end

    test "returns error for payload with nil goal" do
      tp = %TaskPayload{run_id: "run_123", goal: nil}

      assert {:error, [:goal]} = TaskPayload.validate(tp)
    end

    test "returns error for payload with empty run_id" do
      tp = %TaskPayload{run_id: "", goal: "Has goal"}

      assert {:error, [:run_id]} = TaskPayload.validate(tp)
    end

    test "returns error for payload with empty goal" do
      tp = %TaskPayload{run_id: "run_123", goal: ""}

      assert {:error, [:goal]} = TaskPayload.validate(tp)
    end

    test "returns errors for both missing fields" do
      tp = %TaskPayload{run_id: nil, goal: nil}

      assert {:error, missing} = TaskPayload.validate(tp)
      assert :run_id in missing
      assert :goal in missing
    end
  end

  # ── serialize/1 and deserialize/1 ─────────────────────────────────

  describe "serialize/1" do
    test "serializes payload to JSON string" do
      {:ok, tp} =
        TaskPayload.new(%{
          run_id: "run_ser",
          goal: "Serialize me",
          repo: "org/repo",
          skill: "code_change"
        })

      assert {:ok, json} = TaskPayload.serialize(tp)
      assert is_binary(json)

      {:ok, decoded} = Jason.decode(json)
      assert decoded["run_id"] == "run_ser"
      assert decoded["goal"] == "Serialize me"
      assert decoded["repo"] == "org/repo"
      assert decoded["skill"] == "code_change"
      assert decoded["constraints"] == %{}
      assert decoded["answers"] == %{}
      assert decoded["env"] == %{}
    end

    test "round-trips through serialize and deserialize" do
      {:ok, original} =
        TaskPayload.new(%{
          run_id: "run_roundtrip",
          goal: "Round trip test",
          repo: "plattegruber/lattice",
          skill: "open_pr",
          constraints: %{"base_branch" => "main"},
          acceptance: "CI passes",
          answers: %{"question" => "answer"},
          env: %{"TOKEN" => "abc"}
        })

      {:ok, json} = TaskPayload.serialize(original)
      {:ok, restored} = TaskPayload.deserialize(json)

      assert restored.run_id == original.run_id
      assert restored.goal == original.goal
      assert restored.repo == original.repo
      assert restored.skill == original.skill
      assert restored.acceptance == original.acceptance
      # JSON decode converts atom keys to strings
      assert restored.constraints == %{"base_branch" => "main"}
      assert restored.answers == %{"question" => "answer"}
      assert restored.env == %{"TOKEN" => "abc"}
    end
  end

  describe "deserialize/1" do
    test "deserializes valid JSON to payload" do
      json = ~s({"run_id":"run_de","goal":"Deserialize me"})

      assert {:ok, %TaskPayload{} = tp} = TaskPayload.deserialize(json)
      assert tp.run_id == "run_de"
      assert tp.goal == "Deserialize me"
    end

    test "returns error for invalid JSON" do
      assert {:error, _reason} = TaskPayload.deserialize("not valid json{{{")
    end

    test "returns error for JSON missing required fields" do
      json = ~s({"repo":"org/repo"})

      assert {:error, missing} = TaskPayload.deserialize(json)
      assert :run_id in missing
      assert :goal in missing
    end
  end
end
