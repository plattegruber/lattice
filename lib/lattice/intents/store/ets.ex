defmodule Lattice.Intents.Store.ETS do
  @moduledoc """
  ETS-backed implementation of the IntentStore behaviour.

  A GenServer that owns an ETS table for durable (in-memory) intent
  persistence. The table survives individual process crashes via the
  supervisor — the GenServer is the table owner and is restarted on failure.

  ## Design

  - ETS table: `:set`, `:protected`, `:named_table`
  - All reads and writes go through `GenServer.call` for serialized access
  - Filtering uses `:ets.foldl` with predicate composition
  - Post-approval immutability is enforced before writes

  ## Migration Path

  This module implements `Lattice.Intents.Store` behaviour. When PostgreSQL
  persistence is needed, a new implementation can be swapped in via config:

      config :lattice, :intent_store, Lattice.Intents.Store.Postgres
  """

  use GenServer

  @behaviour Lattice.Intents.Store

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Lifecycle
  alias Lattice.Intents.Plan

  @table_name :lattice_intents
  @frozen_fields [
    :payload,
    :affected_resources,
    :expected_side_effects,
    :rollback_strategy,
    :plan
  ]
  @post_approval_states [
    :approved,
    :running,
    :blocked,
    :waiting_for_input,
    :completed,
    :failed,
    :rejected,
    :canceled
  ]

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Lattice.Intents.Store
  def create(%Intent{} = intent) do
    GenServer.call(__MODULE__, {:create, intent})
  end

  @impl Lattice.Intents.Store
  def get(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @impl Lattice.Intents.Store
  def list(filters \\ %{}) when is_map(filters) do
    GenServer.call(__MODULE__, {:list, filters})
  end

  @impl Lattice.Intents.Store
  def list_by_sprite(sprite_name) when is_binary(sprite_name) do
    GenServer.call(__MODULE__, {:list_by_sprite, sprite_name})
  end

  @impl Lattice.Intents.Store
  def update(id, changes) when is_binary(id) and is_map(changes) do
    GenServer.call(__MODULE__, {:update, id, changes})
  end

  @impl Lattice.Intents.Store
  def add_artifact(id, artifact) when is_binary(id) and is_map(artifact) do
    GenServer.call(__MODULE__, {:add_artifact, id, artifact})
  end

  @impl Lattice.Intents.Store
  def get_history(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:get_history, id})
  end

  @impl Lattice.Intents.Store
  def update_plan_step(intent_id, step_id, status, output \\ nil)
      when is_binary(intent_id) and is_binary(step_id) and is_atom(status) do
    GenServer.call(__MODULE__, {:update_plan_step, intent_id, step_id, status, output})
  end

  @doc """
  Clear all intents from the store. Intended for test cleanup only.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table_name, [:set, :protected, :named_table])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call({:create, %Intent{} = intent}, _from, state) do
    case :ets.lookup(state.table, intent.id) do
      [] ->
        :ets.insert(state.table, {intent.id, intent})
        {:reply, {:ok, intent}, state}

      [_] ->
        {:reply, {:error, :already_exists}, state}
    end
  end

  def handle_call({:get, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, intent}] -> {:reply, {:ok, intent}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list, filters}, _from, state) do
    predicates = build_predicates(filters)

    intents =
      :ets.foldl(
        fn {_id, intent}, acc -> collect_if_matching(intent, predicates, acc) end,
        [],
        state.table
      )

    sorted = Enum.sort_by(intents, & &1.inserted_at, {:asc, DateTime})
    {:reply, {:ok, sorted}, state}
  end

  def handle_call({:list_by_sprite, sprite_name}, _from, state) do
    intents =
      :ets.foldl(
        fn {_id, intent}, acc ->
          if sprite_match?(intent, sprite_name), do: [intent | acc], else: acc
        end,
        [],
        state.table
      )

    sorted = Enum.sort_by(intents, & &1.updated_at, {:desc, DateTime})
    {:reply, {:ok, sorted}, state}
  end

  def handle_call({:update, id, changes}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, intent}] ->
        case apply_changes(intent, changes) do
          {:ok, updated} ->
            :ets.insert(state.table, {id, updated})
            {:reply, {:ok, updated}, state}

          {:error, _} = error ->
            {:reply, error, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:add_artifact, id, artifact}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, intent}] ->
        now = DateTime.utc_now()
        timestamped_artifact = Map.put_new(artifact, :added_at, now)

        artifacts = Map.get(intent.metadata, :artifacts, [])

        updated_metadata =
          Map.put(intent.metadata, :artifacts, artifacts ++ [timestamped_artifact])

        updated = %{intent | metadata: updated_metadata, updated_at: now}

        :ets.insert(state.table, {id, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_history, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, intent}] ->
        history = Enum.reverse(intent.transition_log)
        {:reply, {:ok, history}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update_plan_step, intent_id, step_id, status, output}, _from, state) do
    case :ets.lookup(state.table, intent_id) do
      [{^intent_id, intent}] ->
        {:reply, do_update_plan_step(intent, intent_id, step_id, status, output, state), state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp do_update_plan_step(%{plan: nil}, _intent_id, _step_id, _status, _output, _state) do
    {:error, :no_plan}
  end

  defp do_update_plan_step(intent, intent_id, step_id, status, output, state) do
    case Plan.update_step_status(intent.plan, step_id, status, output) do
      {:ok, updated_plan} ->
        now = DateTime.utc_now()
        updated = %{intent | plan: updated_plan, updated_at: now}
        :ets.insert(state.table, {intent_id, updated})
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  defp sprite_match?(intent, sprite_name) do
    source_match =
      intent.source.type == :sprite and intent.source.id == sprite_name

    payload_match =
      Map.get(intent.payload, "sprite_name") == sprite_name

    source_match or payload_match
  end

  defp collect_if_matching(intent, predicates, acc) do
    if Enum.all?(predicates, fn pred -> pred.(intent) end) do
      [intent | acc]
    else
      acc
    end
  end

  # ── Private: Change Application ─────────────────────────────────────

  defp apply_changes(intent, changes) do
    with :ok <- check_immutability(intent, changes) do
      if Map.has_key?(changes, :state) do
        apply_transition(intent, changes)
      else
        apply_field_updates(intent, changes)
      end
    end
  end

  defp apply_transition(intent, changes) do
    new_state = Map.fetch!(changes, :state)
    actor = Map.get(changes, :actor)
    reason = Map.get(changes, :reason)

    case Lifecycle.transition(intent, new_state, actor: actor, reason: reason) do
      {:ok, transitioned} ->
        # Apply any additional field changes alongside the transition
        remaining =
          changes
          |> Map.delete(:state)
          |> Map.delete(:actor)
          |> Map.delete(:reason)

        apply_field_updates(transitioned, remaining)

      {:error, _} = error ->
        error
    end
  end

  defp apply_field_updates(intent, changes) do
    now = DateTime.utc_now()

    updated =
      changes
      |> Enum.reduce(intent, fn
        {:summary, value}, acc -> %{acc | summary: value}
        {:metadata, value}, acc -> %{acc | metadata: value}
        {:result, value}, acc -> %{acc | result: value}
        {:classification, value}, acc -> %{acc | classification: value}
        {:payload, value}, acc -> %{acc | payload: value}
        {:affected_resources, value}, acc -> %{acc | affected_resources: value}
        {:expected_side_effects, value}, acc -> %{acc | expected_side_effects: value}
        {:rollback_strategy, value}, acc -> %{acc | rollback_strategy: value}
        {:plan, value}, acc -> %{acc | plan: value}
        {:blocked_reason, value}, acc -> %{acc | blocked_reason: value}
        {:pending_question, value}, acc -> %{acc | pending_question: value}
        _unknown, acc -> acc
      end)
      |> Map.put(:updated_at, now)

    {:ok, updated}
  end

  # ── Private: Immutability ───────────────────────────────────────────

  defp check_immutability(intent, changes) do
    if intent.state in @post_approval_states do
      frozen_attempted =
        Enum.any?(@frozen_fields, fn field ->
          Map.has_key?(changes, field)
        end)

      if frozen_attempted, do: {:error, :immutable}, else: :ok
    else
      :ok
    end
  end

  # ── Private: Filter Predicates ──────────────────────────────────────

  defp build_predicates(filters) do
    []
    |> maybe_add_predicate(filters, :kind, fn intent, kind -> intent.kind == kind end)
    |> maybe_add_predicate(filters, :state, fn intent, st -> intent.state == st end)
    |> maybe_add_predicate(filters, :source_type, fn intent, source_type ->
      intent.source.type == source_type
    end)
    |> maybe_add_predicate(filters, :since, fn intent, since ->
      DateTime.compare(intent.inserted_at, since) in [:gt, :eq]
    end)
    |> maybe_add_predicate(filters, :until, fn intent, until_dt ->
      DateTime.compare(intent.inserted_at, until_dt) in [:lt, :eq]
    end)
  end

  defp maybe_add_predicate(predicates, filters, key, pred_fn) do
    case Map.fetch(filters, key) do
      {:ok, value} -> [fn intent -> pred_fn.(intent, value) end | predicates]
      :error -> predicates
    end
  end
end
