defmodule Lattice.Intents.ExecutionResultTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.ExecutionResult

  @now DateTime.utc_now()
  @later DateTime.add(@now, 1, :second)

  describe "success/4" do
    test "creates a success result with required fields" do
      assert {:ok, result} = ExecutionResult.success(150, @now, @later)

      assert result.status == :success
      assert result.duration_ms == 150
      assert result.started_at == @now
      assert result.completed_at == @later
      assert result.output == nil
      assert result.artifacts == []
      assert result.error == nil
      assert result.executor == nil
    end

    test "accepts optional output" do
      {:ok, result} = ExecutionResult.success(100, @now, @later, output: %{data: "hello"})

      assert result.output == %{data: "hello"}
    end

    test "accepts optional artifacts" do
      artifacts = [%{type: "log", data: "output"}]
      {:ok, result} = ExecutionResult.success(100, @now, @later, artifacts: artifacts)

      assert result.artifacts == artifacts
    end

    test "accepts optional executor" do
      {:ok, result} = ExecutionResult.success(100, @now, @later, executor: SomeModule)

      assert result.executor == SomeModule
    end

    test "rejects negative duration" do
      assert_raise FunctionClauseError, fn ->
        ExecutionResult.success(-1, @now, @later)
      end
    end
  end

  describe "failure/4" do
    test "creates a failure result with required fields" do
      assert {:ok, result} = ExecutionResult.failure(200, @now, @later)

      assert result.status == :failure
      assert result.duration_ms == 200
      assert result.started_at == @now
      assert result.completed_at == @later
      assert result.error == nil
      assert result.output == nil
      assert result.artifacts == []
    end

    test "accepts optional error details" do
      {:ok, result} = ExecutionResult.failure(100, @now, @later, error: :timeout)

      assert result.error == :timeout
    end

    test "accepts optional partial output" do
      {:ok, result} = ExecutionResult.failure(100, @now, @later, output: "partial data")

      assert result.output == "partial data"
    end

    test "accepts optional artifacts produced before failure" do
      artifacts = [%{type: "partial", data: "before crash"}]
      {:ok, result} = ExecutionResult.failure(100, @now, @later, artifacts: artifacts)

      assert result.artifacts == artifacts
    end

    test "accepts optional executor" do
      {:ok, result} = ExecutionResult.failure(100, @now, @later, executor: AnotherModule)

      assert result.executor == AnotherModule
    end
  end

  describe "success?/1" do
    test "returns true for success results" do
      {:ok, result} = ExecutionResult.success(100, @now, @later)

      assert ExecutionResult.success?(result) == true
    end

    test "returns false for failure results" do
      {:ok, result} = ExecutionResult.failure(100, @now, @later)

      assert ExecutionResult.success?(result) == false
    end
  end

  describe "valid_statuses/0" do
    test "returns success and failure" do
      assert ExecutionResult.valid_statuses() == [:success, :failure]
    end
  end
end
