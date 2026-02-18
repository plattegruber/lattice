defmodule Lattice.Intents.RunBridgeTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  @valid_source %{type: :sprite, id: "sprite-001"}

  setup do
    StoreETS.reset()
    :ok
  end

  defp create_running_intent do
    {:ok, intent} =
      Intent.new_action(@valid_source,
        summary: "Test action",
        payload: %{"target" => "prod"},
        affected_resources: ["fly-app-1"],
        expected_side_effects: ["app restarted"]
      )

    {:ok, _} = Store.create(intent)
    {:ok, _} = Store.update(intent.id, %{state: :classified})
    {:ok, _} = Store.update(intent.id, %{state: :approved})
    {:ok, _} = Store.update(intent.id, %{state: :running})
    {:ok, running} = Store.get(intent.id)
    running
  end

  describe "run_blocked → intent blocked" do
    test "transitions intent to :blocked when run blocks" do
      intent = create_running_intent()

      run = %{
        intent_id: intent.id,
        status: :blocked,
        blocked_reason: "missing credentials"
      }

      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_blocked, run})

      # Give the RunBridge time to process
      Process.sleep(50)

      {:ok, updated} = Store.get(intent.id)
      assert updated.state == :blocked
      assert updated.blocked_reason == "missing credentials"
      assert %DateTime{} = updated.blocked_at
    end

    test "transitions intent to :waiting_for_input when run blocks for user" do
      intent = create_running_intent()

      question = %{
        "prompt" => "Which database adapter?",
        "choices" => ["Ecto.Multi", "separate transactions"],
        "default" => "Ecto.Multi"
      }

      run = %{
        intent_id: intent.id,
        status: :blocked_waiting_for_user,
        question: question
      }

      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_blocked, run})

      Process.sleep(50)

      {:ok, updated} = Store.get(intent.id)
      assert updated.state == :waiting_for_input
      assert updated.pending_question == question
    end

    test "ignores run_blocked when intent_id is nil" do
      run = %{intent_id: nil, status: :blocked, blocked_reason: "test"}

      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_blocked, run})

      Process.sleep(50)
      # No crash, bridge continues
    end

    test "ignores run_blocked when intent is not in :running state" do
      {:ok, intent} =
        Intent.new_maintenance(@valid_source, summary: "Test", payload: %{})

      {:ok, _} = Store.create(intent)

      run = %{intent_id: intent.id, status: :blocked, blocked_reason: "test"}

      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_blocked, run})

      Process.sleep(50)

      {:ok, still_proposed} = Store.get(intent.id)
      assert still_proposed.state == :proposed
    end
  end

  describe "run_resumed → intent resumed" do
    test "transitions intent back to :running from :blocked" do
      intent = create_running_intent()

      # First block it
      {:ok, _} =
        Store.update(intent.id, %{
          state: :blocked,
          blocked_reason: "test block",
          actor: :test
        })

      run = %{intent_id: intent.id}

      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_resumed, run})

      Process.sleep(50)

      {:ok, updated} = Store.get(intent.id)
      assert updated.state == :running
      assert updated.blocked_reason == nil
      assert updated.pending_question == nil
      assert %DateTime{} = updated.resumed_at
    end

    test "transitions intent back to :running from :waiting_for_input" do
      intent = create_running_intent()

      # First set to waiting
      {:ok, _} =
        Store.update(intent.id, %{
          state: :waiting_for_input,
          pending_question: %{"prompt" => "test?"},
          actor: :test
        })

      run = %{intent_id: intent.id}

      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_resumed, run})

      Process.sleep(50)

      {:ok, updated} = Store.get(intent.id)
      assert updated.state == :running
      assert updated.blocked_reason == nil
      assert updated.pending_question == nil
    end

    test "ignores run_resumed when intent_id is nil" do
      run = %{intent_id: nil}

      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_resumed, run})

      Process.sleep(50)
      # No crash, bridge continues
    end

    test "ignores run_resumed when intent is not blocked" do
      intent = create_running_intent()

      run = %{intent_id: intent.id}

      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_resumed, run})

      Process.sleep(50)

      {:ok, still_running} = Store.get(intent.id)
      assert still_running.state == :running
    end
  end

  describe "telemetry events" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "run-bridge-telemetry-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:lattice, :intent, :blocked],
          [:lattice, :intent, :resumed]
        ],
        fn event_name, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event_name, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      %{ref: ref}
    end

    test "emits [:lattice, :intent, :blocked] on block", %{ref: ref} do
      intent = create_running_intent()

      run = %{intent_id: intent.id, status: :blocked, blocked_reason: "test"}
      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_blocked, run})

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :blocked], metadata}, 500
      assert metadata.intent.id == intent.id
    end

    test "emits [:lattice, :intent, :resumed] on resume", %{ref: ref} do
      intent = create_running_intent()

      {:ok, _} =
        Store.update(intent.id, %{
          state: :blocked,
          blocked_reason: "test",
          actor: :test
        })

      run = %{intent_id: intent.id}
      Phoenix.PubSub.broadcast(Lattice.PubSub, Events.runs_topic(), {:run_resumed, run})

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :resumed], metadata}, 500
      assert metadata.intent.id == intent.id
    end
  end
end
