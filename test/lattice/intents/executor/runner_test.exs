defmodule Lattice.Intents.Executor.RunnerTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Executor.Runner
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  setup :verify_on_exit!

  setup do
    StoreETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_approved_intent(opts \\ []) do
    capability = Keyword.get(opts, :capability, "sprites")
    operation = Keyword.get(opts, :operation, "list_sprites")
    args = Keyword.get(opts, :args, [])
    source = Keyword.get(opts, :source, %{type: :sprite, id: "sprite-001"})

    {:ok, intent} =
      Intent.new_action(
        source,
        summary: "Test action",
        payload: %{
          "capability" => capability,
          "operation" => operation,
          "args" => args
        },
        affected_resources: ["test"],
        expected_side_effects: ["test effect"]
      )

    # Manually advance to approved via store operations to avoid
    # pipeline classification/gating interfering with test setup
    {:ok, _stored} = Store.create(intent)
    {:ok, _classified} = Store.update(intent.id, %{state: :classified, classification: :safe})
    {:ok, approved} = Store.update(intent.id, %{state: :approved, actor: :test})
    assert approved.state == :approved

    approved
  end

  defp create_approved_operator_intent(opts \\ []) do
    capability = Keyword.get(opts, :capability, "sprites")
    operation = Keyword.get(opts, :operation, "list_sprites")
    args = Keyword.get(opts, :args, [])

    {:ok, intent} =
      Intent.new_action(
        %{type: :operator, id: "op-001"},
        summary: "Operator action",
        payload: %{
          "capability" => capability,
          "operation" => operation,
          "args" => args
        },
        affected_resources: ["test"],
        expected_side_effects: ["test effect"]
      )

    {:ok, _stored} = Store.create(intent)
    {:ok, _classified} = Store.update(intent.id, %{state: :classified, classification: :safe})
    {:ok, approved} = Store.update(intent.id, %{state: :approved, actor: :test})
    assert approved.state == :approved

    approved
  end

  # ── Successful Execution ────────────────────────────────────────────

  describe "run/1 -- success flow" do
    test "transitions approved intent to completed on success" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, [%{id: "s1"}]} end)

      approved = create_approved_intent()

      assert {:ok, completed} = Runner.run(approved.id)
      assert completed.state == :completed
      assert completed.result != nil
      assert completed.result.status == :success
      assert %DateTime{} = completed.completed_at
    end

    test "records execution result with timing" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn ->
        Process.sleep(5)
        {:ok, []}
      end)

      approved = create_approved_intent()

      assert {:ok, completed} = Runner.run(approved.id)
      assert completed.result.duration_ms >= 5
      assert %DateTime{} = completed.result.started_at
      assert %DateTime{} = completed.result.completed_at
    end

    test "records executor module in result" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, []} end)

      approved = create_approved_intent()

      assert {:ok, completed} = Runner.run(approved.id)
      assert completed.result.executor == Lattice.Intents.Executor.Sprite
    end

    test "stores result in intent store" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, [%{id: "s1"}]} end)

      approved = create_approved_intent()
      {:ok, _completed} = Runner.run(approved.id)

      {:ok, fetched} = Store.get(approved.id)
      assert fetched.state == :completed
      assert fetched.result.status == :success
    end

    test "builds full transition log through execution" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, []} end)

      approved = create_approved_intent()
      {:ok, completed} = Runner.run(approved.id)

      {:ok, history} = Store.get_history(completed.id)
      states = Enum.map(history, & &1.to)

      # classified -> approved -> running -> completed
      assert :running in states
      assert :completed in states
    end

    test "sets started_at on intent when transitioning to running" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, []} end)

      approved = create_approved_intent()
      {:ok, completed} = Runner.run(approved.id)

      assert %DateTime{} = completed.started_at
    end
  end

  # ── Failed Execution ───────────────────────────────────────────────

  describe "run/1 -- failure flow" do
    test "transitions intent to failed when capability returns error" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:error, :api_timeout} end)

      approved = create_approved_intent()

      assert {:ok, result} = Runner.run(approved.id)
      assert result.state == :failed
      assert result.result.status == :failure
    end

    test "records failure result when executor fails with unknown capability" do
      approved = create_approved_intent(capability: "nonexistent", operation: "op")

      assert {:ok, failed} = Runner.run(approved.id)
      assert failed.state == :failed
      assert failed.result.status == :failure
    end

    test "marks intent failed when executor raises" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> raise "boom!" end)

      approved = create_approved_intent()

      assert {:ok, failed} = Runner.run(approved.id)
      assert failed.state == :failed
      assert failed.result != nil
    end

    test "failure records error details in result" do
      approved = create_approved_intent(capability: "nonexistent", operation: "op")

      assert {:ok, failed} = Runner.run(approved.id)
      assert failed.result.error != nil
    end
  end

  # ── Edge Cases ─────────────────────────────────────────────────────

  describe "run/1 -- edge cases" do
    test "returns not_found for missing intent" do
      assert {:error, :not_found} = Runner.run("nonexistent-id")
    end

    test "returns not_approved for proposed intent" do
      {:ok, intent} =
        Intent.new_action(
          %{type: :sprite, id: "sprite-001"},
          summary: "Test",
          payload: %{"capability" => "sprites", "operation" => "list_sprites", "args" => []},
          affected_resources: ["test"],
          expected_side_effects: ["test"]
        )

      {:ok, stored} = Store.create(intent)

      assert {:error, {:not_approved, :proposed}} = Runner.run(stored.id)
    end

    test "marks intent failed when no executor can handle it" do
      # Create an inquiry and manually advance it to approved
      {:ok, intent} =
        Intent.new_inquiry(
          %{type: :operator, id: "op-001"},
          summary: "Need API key",
          payload: %{
            "what_requested" => "API key",
            "why_needed" => "Integration",
            "scope_of_impact" => "single service",
            "expiration" => "2026-03-01"
          }
        )

      {:ok, _stored} = Store.create(intent)
      {:ok, _classified} = Store.update(intent.id, %{state: :classified, classification: :safe})
      {:ok, _approved} = Store.update(intent.id, %{state: :approved, actor: :test})

      assert {:ok, failed} = Runner.run(intent.id)
      assert failed.state == :failed
    end
  end

  # ── run/2 with explicit executor ───────────────────────────────────

  describe "run/2 -- explicit executor" do
    test "uses the specified executor bypassing the router" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, []} end)

      approved = create_approved_operator_intent()

      assert {:ok, completed} =
               Runner.run(approved.id, Lattice.Intents.Executor.ControlPlane)

      assert completed.state == :completed
    end
  end

  # ── Telemetry Events ───────────────────────────────────────────────

  describe "telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "runner-telemetry-test-#{inspect(ref)}"

      events = [
        [:lattice, :intent, :execution, :started],
        [:lattice, :intent, :execution, :completed],
        [:lattice, :intent, :execution, :failed]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "emits :started and :completed for successful execution", %{ref: ref} do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, []} end)

      approved = create_approved_intent()
      {:ok, _} = Runner.run(approved.id)

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :execution, :started], _,
                      %{intent: started}}

      assert started.state == :running

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :execution, :completed], _,
                      %{intent: completed, result: result}}

      assert completed.state == :completed
      assert %ExecutionResult{status: :success} = result
    end

    test "emits :started and :failed for failed execution", %{ref: ref} do
      approved = create_approved_intent(capability: "nonexistent", operation: "op")
      {:ok, _} = Runner.run(approved.id)

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :execution, :started], _,
                      %{intent: _started}}

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :execution, :failed], _,
                      %{intent: failed, error: _error}}

      assert failed.state == :failed
    end

    test "emits :started and :failed when executor crashes", %{ref: ref} do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> raise "kaboom!" end)

      approved = create_approved_intent()
      {:ok, _} = Runner.run(approved.id)

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :execution, :started], _, _}

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :execution, :failed], _,
                      %{intent: failed, error: error}}

      assert failed.state == :failed
      assert is_tuple(error) and elem(error, 0) == :executor_crash
    end
  end

  # ── PubSub Broadcasts ──────────────────────────────────────────────

  describe "PubSub" do
    test "broadcasts execution events on intent-specific topic" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, []} end)

      approved = create_approved_intent()
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{approved.id}")

      {:ok, _} = Runner.run(approved.id)

      assert_receive {:intent_execution_started, started}
      assert started.state == :running

      assert_receive {:intent_execution_completed, completed, _result}
      assert completed.state == :completed
    end

    test "broadcasts execution events on all-intents topic" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:ok, []} end)

      approved = create_approved_intent()
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:all")

      {:ok, _} = Runner.run(approved.id)

      assert_receive {:intent_execution_started, _}
      assert_receive {:intent_execution_completed, _, _}
    end

    test "broadcasts failure events" do
      approved = create_approved_intent(capability: "nonexistent", operation: "op")
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{approved.id}")

      {:ok, _} = Runner.run(approved.id)

      assert_receive {:intent_execution_started, _}
      assert_receive {:intent_execution_failed, failed, _error}
      assert failed.state == :failed
    end
  end

  # ── Artifact Recording ─────────────────────────────────────────────

  describe "artifacts" do
    test "records artifacts from execution result" do
      # Use a custom executor that returns artifacts
      defmodule ArtifactExecutor do
        @behaviour Lattice.Intents.Executor

        alias Lattice.Intents.ExecutionResult

        @impl true
        def can_execute?(_intent), do: true

        @impl true
        def execute(_intent) do
          now = DateTime.utc_now()

          ExecutionResult.success(10, now, now,
            output: "done",
            artifacts: [
              %{type: "log", data: "execution output"},
              %{type: "diff", data: "+line1\n-line2"}
            ]
          )
        end
      end

      approved = create_approved_intent()

      assert {:ok, completed} = Runner.run(approved.id, ArtifactExecutor)
      assert completed.state == :completed

      # Check artifacts were stored
      {:ok, fetched} = Store.get(approved.id)
      artifacts = Map.get(fetched.metadata, :artifacts, [])
      assert length(artifacts) == 2
      assert Enum.any?(artifacts, fn a -> a.type == "log" end)
      assert Enum.any?(artifacts, fn a -> a.type == "diff" end)
    end
  end
end
