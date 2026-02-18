defmodule Lattice.Runs.Run do
  @moduledoc """
  A Run represents a unit of work done by a sprite in service of an intent.

  It bridges the "why" (intent) to the "how" (sprite execution). Runs track
  the full lifecycle of sprite work: pending, running, succeeded, failed, or
  canceled.

  ## Lifecycle

      pending → running → succeeded
                       ↘ failed
      pending → canceled
      running → canceled
  """

  @type status :: :pending | :running | :succeeded | :failed | :canceled

  @type t :: %__MODULE__{
          id: String.t(),
          intent_id: String.t() | nil,
          sprite_name: String.t(),
          command: String.t() | nil,
          mode: :exec_post | :exec_ws | :service,
          status: status(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          artifacts: map(),
          exit_code: integer() | nil,
          error: String.t() | nil,
          inserted_at: DateTime.t()
        }

  @enforce_keys [:id, :sprite_name, :mode]
  defstruct [
    :id,
    :intent_id,
    :sprite_name,
    :command,
    :mode,
    :started_at,
    :finished_at,
    :exit_code,
    :error,
    status: :pending,
    artifacts: %{},
    inserted_at: nil
  ]

  # ── Constructors ─────────────────────────────────────────────────────

  @doc "Create a new Run with a generated ID."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) do
    new(Map.new(attrs))
  end

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: generate_id(),
      sprite_name:
        Map.get(attrs, :sprite_name) || raise(ArgumentError, "sprite_name is required"),
      mode: Map.get(attrs, :mode, :exec_ws),
      intent_id: Map.get(attrs, :intent_id),
      command: Map.get(attrs, :command),
      status: :pending,
      artifacts: Map.get(attrs, :artifacts, %{}),
      inserted_at: DateTime.utc_now()
    }
  end

  # ── Lifecycle Transitions ────────────────────────────────────────────

  @doc "Transition run to :running status."
  @spec start(t()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :running}}
  def start(%__MODULE__{status: :pending} = run) do
    {:ok, %{run | status: :running, started_at: DateTime.utc_now()}}
  end

  def start(%__MODULE__{status: status}), do: {:error, {:invalid_transition, status, :running}}

  @doc "Mark run as succeeded."
  @spec complete(t(), map()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :succeeded}}
  def complete(run, attrs \\ %{})

  def complete(%__MODULE__{status: :running} = run, attrs) do
    {:ok,
     %{
       run
       | status: :succeeded,
         finished_at: DateTime.utc_now(),
         exit_code: Map.get(attrs, :exit_code, 0),
         artifacts: Map.merge(run.artifacts, Map.get(attrs, :artifacts, %{}))
     }}
  end

  def complete(%__MODULE__{status: status}, _),
    do: {:error, {:invalid_transition, status, :succeeded}}

  @doc "Mark run as failed."
  @spec fail(t(), map()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :failed}}
  def fail(run, attrs \\ %{})

  def fail(%__MODULE__{status: :running} = run, attrs) do
    {:ok,
     %{
       run
       | status: :failed,
         finished_at: DateTime.utc_now(),
         exit_code: Map.get(attrs, :exit_code),
         error: Map.get(attrs, :error)
     }}
  end

  def fail(%__MODULE__{status: status}, _),
    do: {:error, {:invalid_transition, status, :failed}}

  @doc "Mark run as canceled."
  @spec cancel(t()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :canceled}}
  def cancel(%__MODULE__{status: s} = run) when s in [:pending, :running] do
    {:ok, %{run | status: :canceled, finished_at: DateTime.utc_now()}}
  end

  def cancel(%__MODULE__{status: status}),
    do: {:error, {:invalid_transition, status, :canceled}}

  # ── Helpers ──────────────────────────────────────────────────────────

  @doc "Add artifacts to the run."
  @spec add_artifacts(t(), map()) :: t()
  def add_artifacts(%__MODULE__{} = run, new_artifacts) when is_map(new_artifacts) do
    %{run | artifacts: Map.merge(run.artifacts, new_artifacts)}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp generate_id do
    "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
