defmodule Lattice.Intents.Intent do
  @moduledoc """
  The unit of work in Lattice.

  An Intent is a durable declaration of something the system proposes to do,
  ask, or improve. Nothing happens without an Intent — it is the boundary
  between reasoning and side effects.

  ## Kinds

  - `:action` — produces side effects (deploy, modify infrastructure, scale fleet)
  - `:inquiry` — requests human input or secrets
  - `:maintenance` — proposes system improvements (update base image, pin dependency)

  ## Lifecycle

  All intents start in `:proposed` and move through a state machine managed
  by `Lattice.Intents.Lifecycle`.

      proposed → classified → awaiting_approval → approved → running → completed
                           ↘ approved ──────────────────────────────↗
  """

  @valid_kinds [:action, :inquiry, :maintenance]
  @valid_source_types [:sprite, :agent, :cron, :operator]

  @type kind :: :action | :inquiry | :maintenance
  @type state ::
          :proposed
          | :classified
          | :awaiting_approval
          | :approved
          | :running
          | :completed
          | :failed
          | :rejected
          | :canceled
  @type classification :: :safe | :controlled | :dangerous | nil
  @type source :: %{type: :sprite | :agent | :cron | :operator, id: String.t()}
  @type transition_entry :: %{
          from: state(),
          to: state(),
          timestamp: DateTime.t(),
          actor: term(),
          reason: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          state: state(),
          source: source(),
          summary: String.t(),
          payload: map(),
          classification: classification(),
          result: term(),
          metadata: map(),
          affected_resources: [String.t()],
          expected_side_effects: [String.t()],
          rollback_strategy: String.t() | nil,
          transition_log: [transition_entry()],
          inserted_at: DateTime.t(),
          updated_at: DateTime.t(),
          classified_at: DateTime.t() | nil,
          approved_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :kind, :state, :source, :summary, :payload, :inserted_at, :updated_at]
  defstruct [
    :id,
    :kind,
    :state,
    :source,
    :summary,
    :payload,
    :rollback_strategy,
    :classified_at,
    :approved_at,
    :started_at,
    :completed_at,
    :inserted_at,
    :updated_at,
    classification: nil,
    result: nil,
    metadata: %{},
    affected_resources: [],
    expected_side_effects: [],
    transition_log: []
  ]

  # ── Constructors ─────────────────────────────────────────────────────

  @doc """
  Create a new action intent.

  Actions produce side effects. Requires `source`, `summary`, `payload`,
  `affected_resources` (non-empty list), and `expected_side_effects` (non-empty list).
  """
  @spec new_action(source(), keyword()) :: {:ok, t()} | {:error, term()}
  def new_action(source, opts) do
    with :ok <- validate_required(opts, :summary),
         :ok <- validate_required(opts, :payload),
         :ok <- validate_non_empty_list(opts, :affected_resources),
         :ok <- validate_non_empty_list(opts, :expected_side_effects) do
      build(:action, source, opts)
    end
  end

  @doc """
  Create a new inquiry intent.

  Inquiries request human input or secrets. Payload must include string keys
  `"what_requested"`, `"why_needed"`, `"scope_of_impact"`, and `"expiration"`.
  """
  @spec new_inquiry(source(), keyword()) :: {:ok, t()} | {:error, term()}
  def new_inquiry(source, opts) do
    with :ok <- validate_required(opts, :summary),
         :ok <- validate_required(opts, :payload),
         payload = Keyword.fetch!(opts, :payload),
         :ok <- validate_payload_field(payload, "what_requested"),
         :ok <- validate_payload_field(payload, "why_needed"),
         :ok <- validate_payload_field(payload, "scope_of_impact"),
         :ok <- validate_payload_field(payload, "expiration") do
      build(:inquiry, source, opts)
    end
  end

  @doc """
  Create a new maintenance intent.

  Maintenance intents propose system improvements. Requires `source`,
  `summary`, and `payload`.
  """
  @spec new_maintenance(source(), keyword()) :: {:ok, t()} | {:error, term()}
  def new_maintenance(source, opts) do
    with :ok <- validate_required(opts, :summary),
         :ok <- validate_required(opts, :payload) do
      build(:maintenance, source, opts)
    end
  end

  # ── Public Helpers ───────────────────────────────────────────────────

  @doc "Returns the list of valid intent kinds."
  @spec valid_kinds() :: [kind()]
  def valid_kinds, do: @valid_kinds

  @doc "Returns the list of valid source types."
  @spec valid_source_types() :: [atom()]
  def valid_source_types, do: @valid_source_types

  # ── Private ──────────────────────────────────────────────────────────

  defp build(kind, source, opts) do
    with :ok <- validate_source(source) do
      now = DateTime.utc_now()

      {:ok,
       %__MODULE__{
         id: generate_id(),
         kind: kind,
         state: :proposed,
         source: source,
         summary: Keyword.fetch!(opts, :summary),
         payload: Keyword.fetch!(opts, :payload),
         metadata: Keyword.get(opts, :metadata, %{}),
         affected_resources: Keyword.get(opts, :affected_resources, []),
         expected_side_effects: Keyword.get(opts, :expected_side_effects, []),
         rollback_strategy: Keyword.get(opts, :rollback_strategy),
         inserted_at: now,
         updated_at: now
       }}
    end
  end

  defp generate_id do
    "int_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp validate_source(%{type: type, id: id}) when type in @valid_source_types and is_binary(id),
    do: :ok

  defp validate_source(%{type: type}) when type not in @valid_source_types,
    do: {:error, {:invalid_source_type, type}}

  defp validate_source(_), do: {:error, {:invalid_source, :bad_format}}

  defp validate_required(opts, field) do
    case Keyword.fetch(opts, field) do
      {:ok, _value} -> :ok
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp validate_non_empty_list(opts, field) do
    case Keyword.fetch(opts, field) do
      {:ok, [_ | _]} -> :ok
      {:ok, _} -> {:error, {:missing_field, field}}
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp validate_payload_field(payload, key) when is_map(payload) do
    if Map.has_key?(payload, key) do
      :ok
    else
      {:error, {:missing_payload_field, key}}
    end
  end
end
