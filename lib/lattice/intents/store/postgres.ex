defmodule Lattice.Intents.Store.Postgres do
  @moduledoc """
  PostgreSQL-backed implementation of the IntentStore behaviour.

  Uses Ecto to persist intents to PostgreSQL via the `Lattice.Intents.Schema`
  Ecto schema. All complex fields (payload, metadata, transition_log, plan)
  are stored as JSONB columns.

  ## Design

  - Reads and writes go through `Lattice.Repo`
  - Post-approval immutability is enforced before writes (same rules as ETS)
  - JSON serialization handles atom keys, DateTime values, and Plan structs
  - The ETS store continues to run alongside for caching and fast reads

  ## Configuration

      config :lattice, :intent_store, Lattice.Intents.Store.Postgres
  """

  @behaviour Lattice.Intents.Store

  import Ecto.Query

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Lifecycle
  alias Lattice.Intents.Plan
  alias Lattice.Intents.Schema
  alias Lattice.Repo

  @frozen_fields [
    :payload,
    :affected_resources,
    :expected_side_effects,
    :rollback_strategy,
    :plan
  ]
  @post_approval_states ~w(approved running blocked waiting_for_input completed failed rejected canceled)

  # ── Behaviour Implementation ───────────────────────────────────────

  @impl true
  def create(%Intent{} = intent) do
    changeset = Schema.from_intent(intent)

    case Repo.insert(changeset) do
      {:ok, schema} -> {:ok, Schema.to_intent(schema)}
      {:error, changeset} -> {:error, {:insert_failed, changeset.errors}}
    end
  end

  @impl true
  def get(id) when is_binary(id) do
    case Repo.get(Schema, id) do
      nil -> {:error, :not_found}
      schema -> {:ok, Schema.to_intent(schema)}
    end
  end

  @impl true
  def list(filters \\ %{}) when is_map(filters) do
    query =
      Schema
      |> apply_query_filters(filters)
      |> order_by([i], asc: i.inserted_at)

    {:ok, query |> Repo.all() |> Enum.map(&Schema.to_intent/1)}
  end

  @impl true
  def list_by_sprite(sprite_name) when is_binary(sprite_name) do
    query =
      from i in Schema,
        where:
          (i.source_type == "sprite" and i.source_id == ^sprite_name) or
            fragment("?->>'sprite_name' = ?", i.payload, ^sprite_name),
        order_by: [desc: i.updated_at]

    {:ok, query |> Repo.all() |> Enum.map(&Schema.to_intent/1)}
  end

  @impl true
  def update(id, changes) when is_binary(id) and is_map(changes) do
    case Repo.get(Schema, id) do
      nil ->
        {:error, :not_found}

      schema ->
        intent = Schema.to_intent(schema)

        with :ok <- check_immutability(intent, changes) do
          if Map.has_key?(changes, :state) do
            apply_transition(schema, intent, changes)
          else
            apply_field_updates(schema, intent, changes)
          end
        end
    end
  end

  @impl true
  def add_artifact(id, artifact) when is_binary(id) and is_map(artifact) do
    case Repo.get(Schema, id) do
      nil ->
        {:error, :not_found}

      schema ->
        now = DateTime.utc_now()
        timestamped = Map.put_new(artifact, :added_at, now)
        metadata = atomize_metadata(schema.metadata || %{})
        artifacts = Map.get(metadata, :artifacts, [])
        updated_metadata = Map.put(metadata, :artifacts, artifacts ++ [timestamped])
        str_metadata = stringify_keys(updated_metadata)

        changeset = Ecto.Changeset.change(schema, metadata: str_metadata)

        case Repo.update(changeset) do
          {:ok, updated} -> {:ok, Schema.to_intent(updated)}
          {:error, _} = error -> error
        end
    end
  end

  @impl true
  def get_history(id) when is_binary(id) do
    case Repo.get(Schema, id) do
      nil ->
        {:error, :not_found}

      schema ->
        intent = Schema.to_intent(schema)
        history = Enum.reverse(intent.transition_log)
        {:ok, history}
    end
  end

  @impl true
  def update_plan_step(intent_id, step_id, status, output \\ nil)
      when is_binary(intent_id) and is_binary(step_id) and is_atom(status) do
    case Repo.get(Schema, intent_id) do
      nil ->
        {:error, :not_found}

      schema ->
        intent = Schema.to_intent(schema)

        case intent.plan do
          nil ->
            {:error, :no_plan}

          plan ->
            case Plan.update_step_status(plan, step_id, status, output) do
              {:ok, updated_plan} ->
                changeset =
                  Ecto.Changeset.change(schema, plan: Plan.to_map(updated_plan))

                case Repo.update(changeset) do
                  {:ok, updated} -> {:ok, Schema.to_intent(updated)}
                  {:error, _} = error -> error
                end

              {:error, _} = error ->
                error
            end
        end
    end
  end

  # ── Private: Transitions ──────────────────────────────────────────

  defp apply_transition(schema, intent, changes) do
    new_state = Map.fetch!(changes, :state)
    actor = Map.get(changes, :actor)
    reason = Map.get(changes, :reason)

    case Lifecycle.transition(intent, new_state, actor: actor, reason: reason) do
      {:ok, transitioned} ->
        remaining = Map.drop(changes, [:state, :actor, :reason])
        merged = merge_intent_to_attrs(transitioned, remaining)
        changeset = Schema.update_changeset(schema, merged)

        case Repo.update(changeset) do
          {:ok, updated} -> {:ok, Schema.to_intent(updated)}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp apply_field_updates(schema, _intent, changes) do
    changeset = Schema.update_changeset(schema, changes)

    case Repo.update(changeset) do
      {:ok, updated} -> {:ok, Schema.to_intent(updated)}
      {:error, _} = error -> error
    end
  end

  defp merge_intent_to_attrs(intent, remaining_changes) do
    # Build attrs from the transitioned intent (which has updated state,
    # timestamps, transition_log) and merge remaining field changes
    base = %{
      state: intent.state,
      transition_log: Enum.map(intent.transition_log, &transition_to_map/1),
      classified_at: intent.classified_at,
      approved_at: intent.approved_at,
      started_at: intent.started_at,
      completed_at: intent.completed_at,
      blocked_at: intent.blocked_at,
      resumed_at: intent.resumed_at
    }

    Map.merge(base, remaining_changes)
  end

  defp transition_to_map(%{from: from, to: to, timestamp: ts} = entry) do
    %{
      "from" => to_string(from),
      "to" => to_string(to),
      "timestamp" => DateTime.to_iso8601(ts),
      "actor" => entry[:actor] && to_string(entry[:actor]),
      "reason" => entry[:reason]
    }
  end

  # ── Private: Immutability ──────────────────────────────────────────

  defp check_immutability(intent, changes) do
    if to_string(intent.state) in @post_approval_states do
      frozen_attempted = Enum.any?(@frozen_fields, &Map.has_key?(changes, &1))
      if frozen_attempted, do: {:error, :immutable}, else: :ok
    else
      :ok
    end
  end

  # ── Private: Query Filters ─────────────────────────────────────────

  defp apply_query_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:kind, kind}, q -> where(q, [i], i.kind == ^to_string(kind))
      {:state, state}, q -> where(q, [i], i.state == ^to_string(state))
      {:source_type, st}, q -> where(q, [i], i.source_type == ^to_string(st))
      {:since, since}, q -> where(q, [i], i.inserted_at >= ^since)
      {:until, until_dt}, q -> where(q, [i], i.inserted_at <= ^until_dt)
      _, q -> q
    end)
  end

  # ── Private: Helpers ───────────────────────────────────────────────

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp atomize_metadata(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> k
          end

        {atom_key, v}

      {k, v} ->
        {k, v}
    end)
  end
end
