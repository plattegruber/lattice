defmodule Lattice.Intents.Store do
  @moduledoc """
  Behaviour and public API for intent persistence.

  Defines the contract for intent storage backends and provides a thin
  public API that wraps the configured implementation with telemetry,
  PubSub, and audit integration.

  ## Behaviour Callbacks

  Implementations must provide:

  - `create/1` — persist a new intent
  - `get/1` — fetch by ID
  - `list/1` — filter by kind, state, source type, date range
  - `update/2` — update mutable fields with immutability enforcement
  - `add_artifact/2` — append artifact to intent metadata
  - `get_history/1` — return full transition timeline

  ## Immutability

  Once an intent reaches `:approved` or beyond, the following fields are
  frozen: `payload`, `affected_resources`, `expected_side_effects`,
  `rollback_strategy`. Attempts to mutate frozen fields return
  `{:error, :immutable}`.

  ## Events

  Every store mutation emits:

  - A Telemetry event (`[:lattice, :intent, :created]`, etc.)
  - A PubSub broadcast on the `"intents"` topic
  - An audit entry via `Lattice.Safety.Audit`
  """

  alias Lattice.Intents.Intent
  alias Lattice.Safety.Audit

  @type filters :: %{
          optional(:kind) => Intent.kind(),
          optional(:state) => Intent.state(),
          optional(:source_type) => atom(),
          optional(:since) => DateTime.t(),
          optional(:until) => DateTime.t()
        }

  @callback create(Intent.t()) :: {:ok, Intent.t()} | {:error, term()}
  @callback get(String.t()) :: {:ok, Intent.t()} | {:error, :not_found}
  @callback list(filters()) :: {:ok, [Intent.t()]}
  @callback update(String.t(), map()) :: {:ok, Intent.t()} | {:error, term()}
  @callback add_artifact(String.t(), map()) :: {:ok, Intent.t()} | {:error, term()}
  @callback get_history(String.t()) :: {:ok, [Intent.transition_entry()]} | {:error, :not_found}

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Persist a new intent.

  Emits `[:lattice, :intent, :created]` telemetry, broadcasts on PubSub,
  and logs an audit entry.
  """
  @spec create(Intent.t()) :: {:ok, Intent.t()} | {:error, term()}
  def create(%Intent{} = intent) do
    case impl().create(intent) do
      {:ok, intent} = result ->
        emit_telemetry([:lattice, :intent, :created], %{intent: intent})
        broadcast({:intent_created, intent})
        Audit.log(:intents, :create, :safe, :ok, :system, args: [intent.id])
        result

      error ->
        error
    end
  end

  @doc """
  Fetch an intent by ID.
  """
  @spec get(String.t()) :: {:ok, Intent.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    impl().get(id)
  end

  @doc """
  List intents matching the given filters.

  ## Supported Filters

  - `:kind` — filter by intent kind (`:action`, `:inquiry`, `:maintenance`)
  - `:state` — filter by lifecycle state
  - `:source_type` — filter by source type (`:sprite`, `:agent`, `:cron`, `:operator`)
  - `:since` — only intents created at or after this DateTime
  - `:until` — only intents created at or before this DateTime
  """
  @spec list(filters()) :: {:ok, [Intent.t()]}
  def list(filters \\ %{}) when is_map(filters) do
    impl().list(filters)
  end

  @doc """
  Update an intent's mutable fields.

  Accepts a map of changes. When `:state` is included, delegates to
  `Lattice.Intents.Lifecycle.transition/3` for validation. Enforces
  post-approval immutability on frozen fields.

  ## Options in changes map

  - `:state` — new lifecycle state (validated by Lifecycle)
  - `:actor` — who triggered the transition
  - `:reason` — why the transition happened
  - `:summary` — updated summary (always mutable)
  - `:metadata` — updated metadata (always mutable)
  - `:result` — execution result (always mutable)
  - `:classification` — safety classification (mutable before approval)
  - `:payload` — frozen after approval
  - `:affected_resources` — frozen after approval
  - `:expected_side_effects` — frozen after approval
  - `:rollback_strategy` — frozen after approval
  """
  @spec update(String.t(), map()) :: {:ok, Intent.t()} | {:error, term()}
  def update(id, changes) when is_binary(id) and is_map(changes) do
    case impl().update(id, changes) do
      {:ok, intent} = result ->
        if Map.has_key?(changes, :state), do: emit_transition_events(id, intent)
        result

      error ->
        error
    end
  end

  @doc """
  Add an artifact to an intent.

  Artifacts are maps appended to the intent's `metadata.artifacts` list.
  Each artifact should include at minimum a `:type` and `:data` key.
  """
  @spec add_artifact(String.t(), map()) :: {:ok, Intent.t()} | {:error, term()}
  def add_artifact(id, artifact) when is_binary(id) and is_map(artifact) do
    case impl().add_artifact(id, artifact) do
      {:ok, intent} = result ->
        emit_telemetry([:lattice, :intent, :artifact_added], %{
          intent: intent,
          artifact: artifact
        })

        broadcast({:intent_artifact_added, intent, artifact})
        Audit.log(:intents, :add_artifact, :safe, :ok, :system, args: [id])
        result

      error ->
        error
    end
  end

  @doc """
  Return the full transition history for an intent.

  Returns the transition log in chronological order (oldest first).
  """
  @spec get_history(String.t()) :: {:ok, [Intent.transition_entry()]} | {:error, :not_found}
  def get_history(id) when is_binary(id) do
    impl().get_history(id)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp impl do
    Application.get_env(:lattice, :intent_store, Lattice.Intents.Store.ETS)
  end

  defp emit_telemetry(event_name, metadata) do
    :telemetry.execute(
      event_name,
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Lattice.PubSub, "intents", message)
  end

  defp emit_transition_events(id, intent) do
    from =
      case intent.transition_log do
        [%{from: from_state} | _] -> from_state
        _ -> nil
      end

    emit_telemetry([:lattice, :intent, :transitioned], %{
      intent: intent,
      from: from,
      to: intent.state
    })

    broadcast({:intent_transitioned, intent})

    Audit.log(:intents, :transition, :safe, :ok, :system,
      args: [id, "#{from} -> #{intent.state}"]
    )
  end
end
