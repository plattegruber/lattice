defmodule LatticeWeb.Api.IntentController do
  @moduledoc """
  API controller for intent lifecycle operations.

  Provides endpoints for listing, querying, proposing, approving, rejecting,
  and canceling intents. All business logic delegates to `Lattice.Intents.Pipeline`
  and `Lattice.Intents.Store`.
  """

  use LatticeWeb, :controller

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store

  @valid_kinds ~w(action inquiry maintenance)
  @valid_filter_states ~w(proposed classified awaiting_approval approved running completed failed rejected canceled)
  @valid_source_types ~w(sprite agent cron operator)

  # ── GET /api/intents ───────────────────────────────────────────────

  @doc """
  GET /api/intents — list intents with optional filters.

  Query params: `kind`, `state`, `source_type`
  """
  def index(conn, params) do
    filters = build_filters(params)

    {:ok, intents} = Store.list(filters)

    conn
    |> put_status(200)
    |> json(%{
      data: Enum.map(intents, &serialize_intent/1),
      timestamp: DateTime.utc_now()
    })
  end

  # ── GET /api/intents/:id ──────────────────────────────────────────

  @doc """
  GET /api/intents/:id — intent detail with full transition history.
  """
  def show(conn, %{"id" => intent_id}) do
    with {:ok, intent} <- Store.get(intent_id),
         {:ok, history} <- Store.get_history(intent_id) do
      conn
      |> put_status(200)
      |> json(%{
        data: serialize_intent_detail(intent, history),
        timestamp: DateTime.utc_now()
      })
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Intent not found", code: "INTENT_NOT_FOUND"})
    end
  end

  # ── POST /api/intents ─────────────────────────────────────────────

  @doc """
  POST /api/intents — propose a new intent through the pipeline.

  Body: `{ "kind": "action"|"inquiry"|"maintenance", "source": { "type": "...", "id": "..." }, "summary": "...", "payload": {...}, ... }`
  """
  def create(conn, %{"kind" => kind} = params) when kind in @valid_kinds do
    with {:ok, source} <- parse_source(params),
         {:ok, intent} <- build_intent(kind, source, params),
         {:ok, result} <- Pipeline.propose(intent) do
      conn
      |> put_status(200)
      |> json(%{
        data: serialize_intent(result),
        timestamp: DateTime.utc_now()
      })
    else
      {:error, {:missing_field, field}} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Missing required field: #{field}",
          code: "MISSING_FIELD"
        })

      {:error, {:missing_payload_field, field}} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Missing required payload field: #{field}",
          code: "MISSING_FIELD"
        })

      {:error, {:invalid_source_type, type}} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Invalid source type: #{type}. Allowed: #{inspect(@valid_source_types)}",
          code: "INVALID_SOURCE_TYPE"
        })

      {:error, {:invalid_source, :bad_format}} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Invalid source format. Required: {\"type\": \"...\", \"id\": \"...\"}",
          code: "MISSING_FIELD"
        })

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Failed to create intent: #{inspect(reason)}",
          code: "INVALID_KIND"
        })
    end
  end

  def create(conn, %{"kind" => invalid_kind}) do
    conn
    |> put_status(422)
    |> json(%{
      error: "Invalid kind: #{inspect(invalid_kind)}. Allowed: #{inspect(@valid_kinds)}",
      code: "INVALID_KIND"
    })
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{
      error: "Missing required field: kind",
      code: "MISSING_FIELD"
    })
  end

  # ── POST /api/intents/:id/approve ─────────────────────────────────

  @doc """
  POST /api/intents/:id/approve — approve an awaiting intent.

  Body: `{ "actor": "..." }`
  """
  def approve(conn, %{"id" => intent_id, "actor" => actor}) do
    case Pipeline.approve(intent_id, actor: actor) do
      {:ok, approved} ->
        conn
        |> put_status(200)
        |> json(%{
          data: serialize_intent(approved),
          timestamp: DateTime.utc_now()
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Intent not found", code: "INTENT_NOT_FOUND"})

      {:error, {:invalid_transition, _} = reason} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Invalid state transition: #{inspect(reason)}",
          code: "INVALID_TRANSITION"
        })
    end
  end

  def approve(conn, %{"id" => _intent_id}) do
    conn
    |> put_status(422)
    |> json(%{
      error: "Missing required field: actor",
      code: "MISSING_FIELD"
    })
  end

  # ── POST /api/intents/:id/reject ──────────────────────────────────

  @doc """
  POST /api/intents/:id/reject — reject an awaiting intent.

  Body: `{ "actor": "...", "reason": "..." }`
  """
  def reject(conn, %{"id" => intent_id, "actor" => actor} = params) do
    reason = Map.get(params, "reason", "rejected")

    case Pipeline.reject(intent_id, actor: actor, reason: reason) do
      {:ok, rejected} ->
        conn
        |> put_status(200)
        |> json(%{
          data: serialize_intent(rejected),
          timestamp: DateTime.utc_now()
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Intent not found", code: "INTENT_NOT_FOUND"})

      {:error, {:invalid_transition, _} = reason_err} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Invalid state transition: #{inspect(reason_err)}",
          code: "INVALID_TRANSITION"
        })
    end
  end

  def reject(conn, %{"id" => _intent_id}) do
    conn
    |> put_status(422)
    |> json(%{
      error: "Missing required field: actor",
      code: "MISSING_FIELD"
    })
  end

  # ── POST /api/intents/:id/cancel ──────────────────────────────────

  @doc """
  POST /api/intents/:id/cancel — cancel an intent from any pre-execution state.

  Body: `{ "actor": "...", "reason": "..." }`
  """
  def cancel(conn, %{"id" => intent_id, "actor" => actor} = params) do
    reason = Map.get(params, "reason", "canceled")

    case Pipeline.cancel(intent_id, actor: actor, reason: reason) do
      {:ok, canceled} ->
        conn
        |> put_status(200)
        |> json(%{
          data: serialize_intent(canceled),
          timestamp: DateTime.utc_now()
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Intent not found", code: "INTENT_NOT_FOUND"})

      {:error, {:invalid_transition, _} = reason_err} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Invalid state transition: #{inspect(reason_err)}",
          code: "INVALID_TRANSITION"
        })
    end
  end

  def cancel(conn, %{"id" => _intent_id}) do
    conn
    |> put_status(422)
    |> json(%{
      error: "Missing required field: actor",
      code: "MISSING_FIELD"
    })
  end

  # ── Private: Filters ──────────────────────────────────────────────

  defp build_filters(params) do
    %{}
    |> maybe_add_filter(params, "kind", &parse_kind/1)
    |> maybe_add_filter(params, "state", &parse_state/1)
    |> maybe_add_filter(params, "source_type", &parse_source_type/1)
  end

  defp maybe_add_filter(filters, params, key, parser) do
    case Map.fetch(params, key) do
      {:ok, value} ->
        case parser.(value) do
          {:ok, parsed} -> Map.put(filters, String.to_existing_atom(key), parsed)
          :error -> filters
        end

      :error ->
        filters
    end
  end

  defp parse_kind(kind) when kind in @valid_kinds, do: {:ok, String.to_existing_atom(kind)}
  defp parse_kind(_), do: :error

  defp parse_state(state) when state in @valid_filter_states,
    do: {:ok, String.to_existing_atom(state)}

  defp parse_state(_), do: :error

  defp parse_source_type(type) when type in @valid_source_types,
    do: {:ok, String.to_existing_atom(type)}

  defp parse_source_type(_), do: :error

  # ── Private: Intent Construction ──────────────────────────────────

  defp parse_source(%{"source" => %{"type" => type, "id" => id}})
       when is_binary(type) and is_binary(id) do
    {:ok, %{type: safe_to_atom(type), id: id}}
  end

  defp parse_source(%{"source" => _}), do: {:error, {:invalid_source, :bad_format}}
  defp parse_source(_), do: {:error, {:missing_field, :source}}

  defp safe_to_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  defp build_intent("action", source, params) do
    Intent.new_action(source,
      summary: Map.get(params, "summary", ""),
      payload: Map.get(params, "payload", %{}),
      affected_resources: Map.get(params, "affected_resources", []),
      expected_side_effects: Map.get(params, "expected_side_effects", []),
      rollback_strategy: Map.get(params, "rollback_strategy")
    )
  end

  defp build_intent("inquiry", source, params) do
    Intent.new_inquiry(source,
      summary: Map.get(params, "summary", ""),
      payload: Map.get(params, "payload", %{})
    )
  end

  defp build_intent("maintenance", source, params) do
    Intent.new_maintenance(source,
      summary: Map.get(params, "summary", ""),
      payload: Map.get(params, "payload", %{})
    )
  end

  # ── Private: Serialization ────────────────────────────────────────

  defp serialize_intent(%Intent{} = intent) do
    %{
      id: intent.id,
      kind: intent.kind,
      state: intent.state,
      source: intent.source,
      summary: intent.summary,
      classification: intent.classification,
      inserted_at: intent.inserted_at,
      updated_at: intent.updated_at
    }
  end

  defp serialize_intent_detail(%Intent{} = intent, history) do
    %{
      id: intent.id,
      kind: intent.kind,
      state: intent.state,
      source: intent.source,
      summary: intent.summary,
      payload: intent.payload,
      classification: intent.classification,
      result: intent.result,
      metadata: intent.metadata,
      affected_resources: intent.affected_resources,
      expected_side_effects: intent.expected_side_effects,
      rollback_strategy: intent.rollback_strategy,
      transition_log: Enum.map(history, &serialize_transition/1),
      inserted_at: intent.inserted_at,
      updated_at: intent.updated_at,
      classified_at: intent.classified_at,
      approved_at: intent.approved_at,
      started_at: intent.started_at,
      completed_at: intent.completed_at
    }
  end

  defp serialize_transition(entry) do
    %{
      from: entry.from,
      to: entry.to,
      timestamp: entry.timestamp,
      actor: entry.actor,
      reason: entry.reason
    }
  end
end
