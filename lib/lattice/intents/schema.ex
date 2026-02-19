defmodule Lattice.Intents.Schema do
  @moduledoc """
  Ecto schema for intent persistence in PostgreSQL.

  Maps between the `%Intent{}` struct (process-level) and the database
  representation. Complex fields (payload, metadata, plan, transition_log)
  are stored as JSONB.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Plan

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "intents" do
    field :kind, :string
    field :state, :string
    field :classification, :string
    field :source_type, :string
    field :source_id, :string
    field :summary, :string
    field :payload, :map, default: %{}
    field :metadata, :map, default: %{}
    field :result, :map
    field :affected_resources, {:array, :string}, default: []
    field :expected_side_effects, {:array, :string}, default: []
    field :rollback_strategy, :string
    field :rollback_for, :string
    field :plan, :map
    field :transition_log, {:array, :map}, default: []
    field :blocked_reason, :string
    field :pending_question, :map

    field :classified_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :blocked_at, :utc_datetime_usec
    field :resumed_at, :utc_datetime_usec

    timestamps()
  end

  @doc "Convert an Intent struct to an Ecto changeset for insertion."
  def from_intent(%Intent{} = intent) do
    %__MODULE__{}
    |> changeset(intent_to_attrs(intent))
  end

  @doc "Update an existing schema record with changed fields."
  def update_changeset(%__MODULE__{} = schema, changes) when is_map(changes) do
    attrs =
      changes
      |> Map.drop([:actor, :reason])
      |> Enum.reduce(%{}, fn
        {:state, v}, acc -> Map.put(acc, :state, to_string(v))
        {:classification, v}, acc -> Map.put(acc, :classification, v && to_string(v))
        {:plan, nil}, acc -> Map.put(acc, :plan, nil)
        {:plan, %Plan{} = p}, acc -> Map.put(acc, :plan, Plan.to_map(p))
        {k, v}, acc -> Map.put(acc, k, v)
      end)

    changeset(schema, attrs)
  end

  @doc "Convert an Ecto schema to an Intent struct."
  def to_intent(%__MODULE__{} = schema) do
    %Intent{
      id: schema.id,
      kind: String.to_existing_atom(schema.kind),
      state: String.to_existing_atom(schema.state),
      source: %{type: String.to_existing_atom(schema.source_type), id: schema.source_id},
      summary: schema.summary,
      payload: atomize_keys_shallow(schema.payload || %{}),
      classification: schema.classification && String.to_existing_atom(schema.classification),
      result: schema.result,
      metadata: atomize_keys_shallow(schema.metadata || %{}),
      affected_resources: schema.affected_resources || [],
      expected_side_effects: schema.expected_side_effects || [],
      rollback_strategy: schema.rollback_strategy,
      rollback_for: schema.rollback_for,
      plan: plan_from_map(schema.plan),
      transition_log: Enum.map(schema.transition_log || [], &transition_from_map/1),
      blocked_reason: schema.blocked_reason,
      pending_question: schema.pending_question,
      classified_at: schema.classified_at,
      approved_at: schema.approved_at,
      started_at: schema.started_at,
      completed_at: schema.completed_at,
      blocked_at: schema.blocked_at,
      resumed_at: schema.resumed_at,
      inserted_at: schema.inserted_at,
      updated_at: schema.updated_at
    }
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :id,
      :kind,
      :state,
      :classification,
      :source_type,
      :source_id,
      :summary,
      :payload,
      :metadata,
      :result,
      :affected_resources,
      :expected_side_effects,
      :rollback_strategy,
      :rollback_for,
      :plan,
      :transition_log,
      :blocked_reason,
      :pending_question,
      :classified_at,
      :approved_at,
      :started_at,
      :completed_at,
      :blocked_at,
      :resumed_at
    ])
    |> validate_required([:id, :kind, :state, :source_type, :source_id, :summary])
  end

  defp intent_to_attrs(%Intent{} = intent) do
    %{
      id: intent.id,
      kind: to_string(intent.kind),
      state: to_string(intent.state),
      classification: intent.classification && to_string(intent.classification),
      source_type: to_string(intent.source.type),
      source_id: intent.source.id,
      summary: intent.summary,
      payload: stringify_keys(intent.payload),
      metadata: stringify_keys(intent.metadata),
      result: intent.result,
      affected_resources: intent.affected_resources,
      expected_side_effects: intent.expected_side_effects,
      rollback_strategy: intent.rollback_strategy,
      rollback_for: intent.rollback_for,
      plan: intent.plan && Plan.to_map(intent.plan),
      transition_log: Enum.map(intent.transition_log, &transition_to_map/1),
      blocked_reason: intent.blocked_reason,
      pending_question: intent.pending_question,
      classified_at: intent.classified_at,
      approved_at: intent.approved_at,
      started_at: intent.started_at,
      completed_at: intent.completed_at,
      blocked_at: intent.blocked_at,
      resumed_at: intent.resumed_at
    }
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

  defp transition_from_map(%{"from" => from, "to" => to, "timestamp" => ts} = entry) do
    %{
      from: safe_to_atom(from),
      to: safe_to_atom(to),
      timestamp: parse_datetime(ts),
      actor: entry["actor"] && safe_to_atom(entry["actor"]),
      reason: entry["reason"]
    }
  end

  defp transition_from_map(entry), do: entry

  defp plan_from_map(nil), do: nil
  defp plan_from_map(map) when is_map(map), do: Plan.from_map(map)

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(val) when is_atom(val), do: val

  defp safe_to_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> val
  end

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp atomize_keys_shallow(map) when is_map(map) do
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
