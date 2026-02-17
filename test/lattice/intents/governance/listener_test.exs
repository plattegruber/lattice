defmodule Lattice.Intents.Governance.ListenerTest do
  use ExUnit.Case

  import Mox

  @moduletag :unit

  alias Lattice.Intents.Governance.Labels, as: GovLabels
  alias Lattice.Intents.Governance.Listener
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  @valid_source %{type: :sprite, id: "sprite-001"}

  setup :verify_on_exit!

  setup do
    StoreETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp new_action_intent(opts \\ []) do
    source = Keyword.get(opts, :source, @valid_source)

    {:ok, intent} =
      Intent.new_action(source,
        summary: Keyword.get(opts, :summary, "Wake sprite"),
        payload: %{"capability" => "sprites", "operation" => "wake"},
        affected_resources: ["sprite-001"],
        expected_side_effects: ["sprite wakes"]
      )

    intent
  end

  defp with_guardrails(config, fun) do
    previous = Application.get_env(:lattice, :guardrails, [])
    Application.put_env(:lattice, :guardrails, config)

    try do
      fun.()
    after
      Application.put_env(:lattice, :guardrails, previous)
    end
  end

  # ── Listener creates governance issue on awaiting_approval ──────

  describe "handle_info/2 for awaiting_approval" do
    test "creates governance issue when intent enters awaiting_approval" do
      intent = new_action_intent()

      awaiting =
        with_guardrails(
          [allow_controlled: true, require_approval_for_controlled: true],
          fn ->
            {:ok, awaiting} = Pipeline.propose(intent)
            awaiting
          end
        )

      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn _title, attrs ->
        assert GovLabels.awaiting_approval() in attrs.labels

        {:ok,
         %{
           number: 42,
           title: "test",
           body: "",
           state: "open",
           labels: attrs.labels,
           comments: []
         }}
      end)

      # Simulate the PubSub message the Listener would receive
      state = %{sync_interval_ms: 60_000}

      assert {:noreply, ^state} =
               Listener.handle_info({:intent_awaiting_approval, awaiting}, state)

      # Verify the governance issue was stored in metadata
      {:ok, updated} = Store.get(awaiting.id)
      assert updated.metadata[:governance_issue] == 42
    end
  end

  # ── Listener syncs on periodic tick ─────────────────────────────

  describe "handle_info/2 for sync_governance" do
    test "syncs awaiting intents from GitHub on periodic tick" do
      intent = new_action_intent()

      awaiting =
        with_guardrails(
          [allow_controlled: true, require_approval_for_controlled: true],
          fn ->
            {:ok, awaiting} = Pipeline.propose(intent)
            awaiting
          end
        )

      # Add governance issue to metadata
      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, _with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 ->
        {:ok,
         %{
           number: 42,
           title: "test",
           body: "",
           state: "open",
           labels: [GovLabels.approved()],
           comments: []
         }}
      end)

      state = %{sync_interval_ms: 60_000}

      assert {:noreply, ^state} =
               Listener.handle_info(:sync_governance, state)

      {:ok, updated} = Store.get(awaiting.id)
      assert updated.state == :approved
    end
  end

  # ── Catch-all ───────────────────────────────────────────────────

  describe "handle_info/2 catch-all" do
    test "ignores unknown events" do
      state = %{sync_interval_ms: 60_000}
      assert {:noreply, ^state} = Listener.handle_info(:unknown_event, state)
    end
  end
end
