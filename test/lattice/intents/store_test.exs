defmodule Lattice.Intents.StoreTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  @valid_source %{type: :sprite, id: "sprite-001"}

  setup do
    # Clear the ETS table between tests to avoid cross-contamination
    StoreETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp new_action(opts \\ []) do
    source = Keyword.get(opts, :source, @valid_source)

    {:ok, intent} =
      Intent.new_action(source,
        summary: Keyword.get(opts, :summary, "Deploy app"),
        payload: Keyword.get(opts, :payload, %{"target" => "prod"}),
        affected_resources: Keyword.get(opts, :affected_resources, ["fly-app-1"]),
        expected_side_effects: Keyword.get(opts, :expected_side_effects, ["app restarted"]),
        rollback_strategy: Keyword.get(opts, :rollback_strategy, "redeploy previous"),
        metadata: Keyword.get(opts, :metadata, %{})
      )

    intent
  end

  defp new_maintenance(opts \\ []) do
    source = Keyword.get(opts, :source, @valid_source)

    {:ok, intent} =
      Intent.new_maintenance(source,
        summary: Keyword.get(opts, :summary, "Update base image"),
        payload: Keyword.get(opts, :payload, %{"image" => "elixir:1.18"}),
        metadata: Keyword.get(opts, :metadata, %{})
      )

    intent
  end

  defp new_inquiry(opts \\ []) do
    source = Keyword.get(opts, :source, %{type: :operator, id: "op-001"})

    {:ok, intent} =
      Intent.new_inquiry(source,
        summary: Keyword.get(opts, :summary, "Need API key"),
        payload:
          Keyword.get(opts, :payload, %{
            "what_requested" => "API key",
            "why_needed" => "Integration",
            "scope_of_impact" => "single service",
            "expiration" => "2026-03-01"
          }),
        metadata: Keyword.get(opts, :metadata, %{})
      )

    intent
  end

  defp create_and_store(intent) do
    {:ok, stored} = Store.create(intent)
    stored
  end

  @transition_paths %{
    proposed: [],
    classified: [:classified],
    awaiting_approval: [:classified, :awaiting_approval],
    approved: [:classified, :approved],
    running: [:classified, :approved, :running],
    completed: [:classified, :approved, :running, :completed],
    failed: [:classified, :approved, :running, :failed],
    rejected: [:classified, :awaiting_approval, :rejected],
    canceled: [:classified, :awaiting_approval, :canceled]
  }

  defp advance_to_state(intent, target_state) do
    @transition_paths
    |> Map.fetch!(target_state)
    |> Enum.each(fn state ->
      {:ok, _} =
        Store.update(intent.id, %{state: state, actor: "test", reason: "test transition"})
    end)

    {:ok, updated} = Store.get(intent.id)
    updated
  end

  # ── CRUD Operations ─────────────────────────────────────────────────

  describe "create/1" do
    test "persists a new intent" do
      intent = new_action()
      assert {:ok, stored} = Store.create(intent)
      assert stored.id == intent.id
      assert stored.kind == :action
      assert stored.state == :proposed
    end

    test "rejects duplicate intent IDs" do
      intent = new_action()
      {:ok, _} = Store.create(intent)
      assert {:error, :already_exists} = Store.create(intent)
    end
  end

  describe "get/1" do
    test "retrieves a stored intent by ID" do
      intent = create_and_store(new_action())
      assert {:ok, fetched} = Store.get(intent.id)
      assert fetched.id == intent.id
      assert fetched.summary == "Deploy app"
    end

    test "returns :not_found for missing ID" do
      assert {:error, :not_found} = Store.get("nonexistent-id")
    end
  end

  describe "get_history/1" do
    test "returns empty history for new intent" do
      intent = create_and_store(new_action())
      assert {:ok, []} = Store.get_history(intent.id)
    end

    test "returns transitions in chronological order" do
      intent = create_and_store(new_action())
      {:ok, _} = Store.update(intent.id, %{state: :classified, actor: "system", reason: "auto"})

      {:ok, _} =
        Store.update(intent.id, %{state: :approved, actor: "human", reason: "looks good"})

      {:ok, history} = Store.get_history(intent.id)
      assert length(history) == 2

      [first, second] = history
      assert first.from == :proposed
      assert first.to == :classified
      assert first.actor == "system"
      assert second.from == :classified
      assert second.to == :approved
      assert second.actor == "human"
    end

    test "returns :not_found for missing ID" do
      assert {:error, :not_found} = Store.get_history("nonexistent-id")
    end
  end

  # ── List and Filtering ──────────────────────────────────────────────

  describe "list/1" do
    test "returns empty list when store is empty" do
      assert {:ok, []} = Store.list()
    end

    test "returns all intents when no filters given" do
      create_and_store(new_action())
      create_and_store(new_maintenance())

      {:ok, intents} = Store.list()
      assert length(intents) == 2
    end

    test "filters by kind" do
      create_and_store(new_action())
      create_and_store(new_maintenance())
      create_and_store(new_inquiry())

      {:ok, actions} = Store.list(%{kind: :action})
      assert length(actions) == 1
      assert hd(actions).kind == :action

      {:ok, maintenance} = Store.list(%{kind: :maintenance})
      assert length(maintenance) == 1
      assert hd(maintenance).kind == :maintenance
    end

    test "filters by state" do
      intent = create_and_store(new_action())
      create_and_store(new_maintenance())

      {:ok, _} = Store.update(intent.id, %{state: :classified})

      {:ok, proposed} = Store.list(%{state: :proposed})
      assert length(proposed) == 1
      assert hd(proposed).state == :proposed

      {:ok, classified} = Store.list(%{state: :classified})
      assert length(classified) == 1
      assert hd(classified).state == :classified
    end

    test "filters by source_type" do
      create_and_store(new_action(source: %{type: :sprite, id: "s-1"}))
      create_and_store(new_maintenance(source: %{type: :cron, id: "cron-1"}))

      {:ok, sprites} = Store.list(%{source_type: :sprite})
      assert length(sprites) == 1
      assert hd(sprites).source.type == :sprite

      {:ok, crons} = Store.list(%{source_type: :cron})
      assert length(crons) == 1
      assert hd(crons).source.type == :cron
    end

    test "filters by date range (since)" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      create_and_store(new_action())

      {:ok, since_past} = Store.list(%{since: past})
      assert length(since_past) == 1

      {:ok, since_future} = Store.list(%{since: future})
      assert since_future == []
    end

    test "filters by date range (until)" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      create_and_store(new_action())

      {:ok, until_future} = Store.list(%{until: future})
      assert length(until_future) == 1

      {:ok, until_past} = Store.list(%{until: past})
      assert until_past == []
    end

    test "combines multiple filters" do
      create_and_store(new_action(source: %{type: :sprite, id: "s-1"}))
      create_and_store(new_action(source: %{type: :cron, id: "cron-1"}))
      create_and_store(new_maintenance(source: %{type: :sprite, id: "s-2"}))

      {:ok, results} = Store.list(%{kind: :action, source_type: :sprite})
      assert length(results) == 1
      assert hd(results).kind == :action
      assert hd(results).source.type == :sprite
    end

    test "returns intents sorted by inserted_at ascending" do
      i1 = create_and_store(new_action(summary: "First"))
      i2 = create_and_store(new_maintenance(summary: "Second"))

      {:ok, intents} = Store.list()
      ids = Enum.map(intents, & &1.id)
      assert ids == [i1.id, i2.id]
    end
  end

  # ── Update with Transition ─────────────────────────────────────────

  describe "update/2 state transitions" do
    test "transitions intent state via Lifecycle" do
      intent = create_and_store(new_action())
      assert {:ok, updated} = Store.update(intent.id, %{state: :classified})
      assert updated.state == :classified
    end

    test "appends to transition log on state change" do
      intent = create_and_store(new_action())

      {:ok, updated} =
        Store.update(intent.id, %{state: :classified, actor: "system", reason: "auto-classify"})

      assert [entry] = updated.transition_log
      assert entry.from == :proposed
      assert entry.to == :classified
      assert entry.actor == "system"
      assert entry.reason == "auto-classify"
    end

    test "rejects invalid state transitions" do
      intent = create_and_store(new_action())

      assert {:error, {:invalid_transition, %{from: :proposed, to: :running}}} =
               Store.update(intent.id, %{state: :running})
    end

    test "returns :not_found for missing intent" do
      assert {:error, :not_found} = Store.update("nonexistent", %{state: :classified})
    end

    test "can update other fields alongside transition" do
      intent = create_and_store(new_action())

      {:ok, updated} =
        Store.update(intent.id, %{
          state: :classified,
          classification: :controlled,
          actor: "classifier"
        })

      assert updated.state == :classified
      assert updated.classification == :controlled
    end
  end

  describe "update/2 field updates without transition" do
    test "updates summary" do
      intent = create_and_store(new_action())
      {:ok, updated} = Store.update(intent.id, %{summary: "Updated summary"})
      assert updated.summary == "Updated summary"
    end

    test "updates metadata" do
      intent = create_and_store(new_action())
      {:ok, updated} = Store.update(intent.id, %{metadata: %{"priority" => "high"}})
      assert updated.metadata == %{"priority" => "high"}
    end

    test "updates result" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :running)

      {:ok, updated} = Store.update(advanced.id, %{result: %{status: :success, output: "done"}})
      assert updated.result == %{status: :success, output: "done"}
    end

    test "updates classification before approval" do
      intent = create_and_store(new_action())
      {:ok, updated} = Store.update(intent.id, %{classification: :dangerous})
      assert updated.classification == :dangerous
    end

    test "refreshes updated_at on field update" do
      intent = create_and_store(new_action())
      {:ok, updated} = Store.update(intent.id, %{summary: "New"})
      assert DateTime.compare(updated.updated_at, intent.updated_at) in [:gt, :eq]
    end
  end

  # ── Post-Approval Immutability ──────────────────────────────────────

  describe "post-approval immutability" do
    test "freezes payload after approval" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :approved)

      assert {:error, :immutable} =
               Store.update(advanced.id, %{payload: %{"target" => "staging"}})
    end

    test "freezes affected_resources after approval" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :approved)

      assert {:error, :immutable} =
               Store.update(advanced.id, %{affected_resources: ["new-resource"]})
    end

    test "freezes expected_side_effects after approval" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :approved)

      assert {:error, :immutable} =
               Store.update(advanced.id, %{expected_side_effects: ["new-effect"]})
    end

    test "freezes rollback_strategy after approval" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :approved)

      assert {:error, :immutable} =
               Store.update(advanced.id, %{rollback_strategy: "new strategy"})
    end

    test "allows summary update after approval" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :approved)

      assert {:ok, updated} = Store.update(advanced.id, %{summary: "Updated after approval"})
      assert updated.summary == "Updated after approval"
    end

    test "allows metadata update after approval" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :approved)

      assert {:ok, updated} = Store.update(advanced.id, %{metadata: %{"note" => "approved"}})
      assert updated.metadata == %{"note" => "approved"}
    end

    test "allows result update after approval" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :running)

      assert {:ok, updated} = Store.update(advanced.id, %{result: %{output: "done"}})
      assert updated.result == %{output: "done"}
    end

    test "immutability enforced in running state" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :running)

      assert {:error, :immutable} = Store.update(advanced.id, %{payload: %{"changed" => true}})
    end

    test "immutability enforced in completed state" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :completed)

      assert {:error, :immutable} = Store.update(advanced.id, %{payload: %{"changed" => true}})
    end

    test "immutability enforced in failed state" do
      intent = create_and_store(new_action())
      advanced = advance_to_state(intent, :failed)

      assert {:error, :immutable} = Store.update(advanced.id, %{payload: %{"changed" => true}})
    end

    test "allows payload update before approval" do
      intent = create_and_store(new_action())

      assert {:ok, updated} =
               Store.update(intent.id, %{payload: %{"target" => "staging"}})

      assert updated.payload == %{"target" => "staging"}
    end
  end

  # ── Artifacts ───────────────────────────────────────────────────────

  describe "add_artifact/2" do
    test "appends artifact to intent metadata" do
      intent = create_and_store(new_action())
      artifact = %{type: :log, data: "execution log content"}

      assert {:ok, updated} = Store.add_artifact(intent.id, artifact)
      assert [stored_artifact] = updated.metadata.artifacts
      assert stored_artifact.type == :log
      assert stored_artifact.data == "execution log content"
      assert %DateTime{} = stored_artifact.added_at
    end

    test "appends multiple artifacts" do
      intent = create_and_store(new_action())

      {:ok, _} = Store.add_artifact(intent.id, %{type: :log, data: "first"})
      {:ok, updated} = Store.add_artifact(intent.id, %{type: :screenshot, data: "second"})

      assert length(updated.metadata.artifacts) == 2
      assert Enum.at(updated.metadata.artifacts, 0).type == :log
      assert Enum.at(updated.metadata.artifacts, 1).type == :screenshot
    end

    test "returns :not_found for missing intent" do
      assert {:error, :not_found} = Store.add_artifact("nonexistent", %{type: :log, data: "x"})
    end

    test "refreshes updated_at" do
      intent = create_and_store(new_action())
      {:ok, updated} = Store.add_artifact(intent.id, %{type: :log, data: "x"})
      assert DateTime.compare(updated.updated_at, intent.updated_at) in [:gt, :eq]
    end
  end

  # ── Telemetry Events ────────────────────────────────────────────────

  describe "telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "store-telemetry-test-#{inspect(ref)}"

      events = [
        [:lattice, :intent, :created],
        [:lattice, :intent, :transitioned],
        [:lattice, :intent, :artifact_added]
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

    test "emits [:lattice, :intent, :created] on create", %{ref: ref} do
      intent = new_action()
      {:ok, _} = Store.create(intent)

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :created], measurements, metadata}
      assert %{system_time: _} = measurements
      assert metadata.intent.id == intent.id
    end

    test "emits [:lattice, :intent, :transitioned] on state change", %{ref: ref} do
      intent = create_and_store(new_action())

      # Drain the :created event
      assert_receive {:telemetry, ^ref, [:lattice, :intent, :created], _, _}

      {:ok, _} = Store.update(intent.id, %{state: :classified, actor: "test"})

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :transitioned], measurements,
                      metadata}

      assert %{system_time: _} = measurements
      assert metadata.intent.state == :classified
      assert metadata.from == :proposed
      assert metadata.to == :classified
    end

    test "emits [:lattice, :intent, :artifact_added] on add_artifact", %{ref: ref} do
      intent = create_and_store(new_action())

      # Drain the :created event
      assert_receive {:telemetry, ^ref, [:lattice, :intent, :created], _, _}

      artifact = %{type: :log, data: "test"}
      {:ok, _} = Store.add_artifact(intent.id, artifact)

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :artifact_added], measurements,
                      metadata}

      assert %{system_time: _} = measurements
      assert metadata.intent.id == intent.id
      assert metadata.artifact.type == :log
    end

    test "does not emit transition telemetry for non-state updates", %{ref: ref} do
      intent = create_and_store(new_action())

      # Drain the :created event
      assert_receive {:telemetry, ^ref, [:lattice, :intent, :created], _, _}

      {:ok, _} = Store.update(intent.id, %{summary: "Updated"})

      refute_receive {:telemetry, ^ref, [:lattice, :intent, :transitioned], _, _}, 100
    end
  end

  # ── PubSub Broadcast ────────────────────────────────────────────────

  describe "PubSub" do
    test "broadcasts {:intent_created, intent} on create" do
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents")

      intent = new_action()
      {:ok, stored} = Store.create(intent)

      assert_receive {:intent_created, ^stored}
    end

    test "broadcasts {:intent_transitioned, intent} on state change" do
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents")

      intent = create_and_store(new_action())

      # Drain the :created message
      assert_receive {:intent_created, _}

      {:ok, updated} = Store.update(intent.id, %{state: :classified})

      assert_receive {:intent_transitioned, ^updated}
    end

    test "broadcasts {:intent_artifact_added, intent, artifact} on add_artifact" do
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents")

      intent = create_and_store(new_action())

      # Drain the :created message
      assert_receive {:intent_created, _}

      artifact = %{type: :log, data: "test"}
      {:ok, _} = Store.add_artifact(intent.id, artifact)

      assert_receive {:intent_artifact_added, _intent, received_artifact}
      assert received_artifact.type == :log
    end

    test "does not broadcast on read operations" do
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents")

      intent = create_and_store(new_action())

      # Drain the :created message
      assert_receive {:intent_created, _}

      Store.get(intent.id)
      Store.list()
      Store.get_history(intent.id)

      refute_receive _, 100
    end
  end

  # ── Audit Integration ──────────────────────────────────────────────

  describe "audit" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "store-audit-test-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:lattice, :safety, :audit],
        fn _event_name, _measurements, metadata, _config ->
          send(test_pid, {:audit, ref, metadata.entry})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "logs audit entry on create", %{ref: ref} do
      intent = new_action()
      {:ok, _} = Store.create(intent)

      assert_receive {:audit, ^ref, entry}
      assert entry.capability == :intents
      assert entry.operation == :create
      assert entry.result == :ok
      assert entry.args == [intent.id]
    end

    test "logs audit entry on transition", %{ref: ref} do
      intent = create_and_store(new_action())

      # Drain the :create audit
      assert_receive {:audit, ^ref, _}

      {:ok, _} = Store.update(intent.id, %{state: :classified})

      assert_receive {:audit, ^ref, entry}
      assert entry.capability == :intents
      assert entry.operation == :transition
      assert entry.args == [intent.id, "proposed -> classified"]
    end

    test "logs audit entry on add_artifact", %{ref: ref} do
      intent = create_and_store(new_action())

      # Drain the :create audit
      assert_receive {:audit, ^ref, _}

      {:ok, _} = Store.add_artifact(intent.id, %{type: :log, data: "x"})

      assert_receive {:audit, ^ref, entry}
      assert entry.capability == :intents
      assert entry.operation == :add_artifact
      assert entry.args == [intent.id]
    end
  end

  # ── Full Lifecycle ──────────────────────────────────────────────────

  describe "full lifecycle" do
    test "intent flows through complete happy path" do
      intent = create_and_store(new_action())

      {:ok, i1} = Store.update(intent.id, %{state: :classified, classification: :controlled})
      assert i1.state == :classified
      assert i1.classification == :controlled

      {:ok, i2} = Store.update(intent.id, %{state: :approved, actor: "human", reason: "LGTM"})
      assert i2.state == :approved
      assert %DateTime{} = i2.approved_at

      {:ok, i3} = Store.update(intent.id, %{state: :running})
      assert i3.state == :running

      {:ok, i4} =
        Store.update(intent.id, %{state: :completed, result: %{status: :success}})

      assert i4.state == :completed
      assert i4.result == %{status: :success}

      {:ok, history} = Store.get_history(intent.id)
      assert length(history) == 4
      states = Enum.map(history, & &1.to)
      assert states == [:classified, :approved, :running, :completed]
    end
  end
end
