defmodule Lattice.Runs.Run do
  @moduledoc """
  A Run represents a unit of work done by a sprite in service of an intent.

  It bridges the "why" (intent) to the "how" (sprite execution). Runs track
  the full lifecycle of sprite work: pending, running, succeeded, failed, or
  canceled. Runs can also be blocked (waiting for external resolution) or
  blocked_waiting_for_user (waiting for human input via a question).

  ## Lifecycle

      pending → running → succeeded
                       ↘ failed
      pending → canceled
      running → canceled
      running → blocked → running (resume)
      running → blocked_waiting_for_user → running (resume with answer)
      blocked → canceled
      blocked_waiting_for_user → canceled
      blocked → failed
      blocked_waiting_for_user → failed
  """

  @type status ::
          :pending
          | :running
          | :succeeded
          | :failed
          | :canceled
          | :blocked
          | :blocked_waiting_for_user

  @type t :: %__MODULE__{
          id: String.t(),
          intent_id: String.t() | nil,
          sprite_name: String.t(),
          command: String.t() | nil,
          mode: :exec_post | :exec_ws | :service,
          status: status(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          artifacts: [map()],
          assumptions: [map()],
          exit_code: integer() | nil,
          error: String.t() | nil,
          blocked_reason: String.t() | nil,
          question: map() | nil,
          answer: map() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
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
    :blocked_reason,
    :question,
    :answer,
    status: :pending,
    artifacts: [],
    assumptions: [],
    inserted_at: nil,
    updated_at: nil
  ]

  @valid_modes ~w(exec_post exec_ws service)a

  # ── Constructors ─────────────────────────────────────────────────────

  @doc "Create a new Run with a generated ID."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    new(Map.new(attrs))
  end

  def new(attrs) when is_map(attrs) do
    mode = Map.get(attrs, :mode, :exec_ws)
    sprite_name = Map.get(attrs, :sprite_name)

    cond do
      is_nil(sprite_name) or sprite_name == "" ->
        {:error, {:missing_field, :sprite_name}}

      mode not in @valid_modes ->
        {:error, {:invalid_mode, mode}}

      true ->
        now = DateTime.utc_now()

        {:ok,
         %__MODULE__{
           id: generate_id(),
           sprite_name: sprite_name,
           mode: mode,
           intent_id: Map.get(attrs, :intent_id),
           command: Map.get(attrs, :command),
           status: :pending,
           artifacts: Map.get(attrs, :artifacts, []),
           inserted_at: now,
           updated_at: now
         }}
    end
  end

  # ── Lifecycle Transitions ────────────────────────────────────────────

  @doc "Transition run to :running status."
  @spec start(t()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :running}}
  def start(%__MODULE__{status: :pending} = run) do
    now = DateTime.utc_now()
    {:ok, %{run | status: :running, started_at: now, updated_at: now}}
  end

  def start(%__MODULE__{status: status}), do: {:error, {:invalid_transition, status, :running}}

  @doc "Mark run as succeeded."
  @spec complete(t(), map()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :succeeded}}
  def complete(run, attrs \\ %{})

  def complete(%__MODULE__{status: :running} = run, attrs) do
    now = DateTime.utc_now()

    {:ok,
     %{
       run
       | status: :succeeded,
         finished_at: now,
         updated_at: now,
         exit_code: Map.get(attrs, :exit_code, 0),
         artifacts: run.artifacts ++ List.wrap(Map.get(attrs, :artifacts, []))
     }}
  end

  def complete(%__MODULE__{status: status}, _),
    do: {:error, {:invalid_transition, status, :succeeded}}

  @doc "Mark run as failed."
  @spec fail(t(), map()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :failed}}
  def fail(run, attrs \\ %{})

  def fail(%__MODULE__{status: s} = run, attrs)
      when s in [:running, :blocked, :blocked_waiting_for_user] do
    now = DateTime.utc_now()

    {:ok,
     %{
       run
       | status: :failed,
         finished_at: now,
         updated_at: now,
         exit_code: Map.get(attrs, :exit_code),
         error: Map.get(attrs, :error)
     }}
  end

  def fail(%__MODULE__{status: status}, _),
    do: {:error, {:invalid_transition, status, :failed}}

  @doc "Mark run as canceled."
  @spec cancel(t()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :canceled}}
  def cancel(%__MODULE__{status: s} = run)
      when s in [:pending, :running, :blocked, :blocked_waiting_for_user] do
    now = DateTime.utc_now()
    {:ok, %{run | status: :canceled, finished_at: now, updated_at: now}}
  end

  def cancel(%__MODULE__{status: status}),
    do: {:error, {:invalid_transition, status, :canceled}}

  @doc "Block a running run."
  @spec block(t(), String.t()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :blocked}}
  def block(%__MODULE__{status: :running} = run, reason) do
    {:ok, %{run | status: :blocked, blocked_reason: reason, updated_at: DateTime.utc_now()}}
  end

  def block(%__MODULE__{status: status}, _),
    do: {:error, {:invalid_transition, status, :blocked}}

  @doc "Block a running run for user input."
  @spec block_for_input(t(), map()) ::
          {:ok, t()} | {:error, {:invalid_transition, status(), :blocked_waiting_for_user}}
  def block_for_input(%__MODULE__{status: :running} = run, question) do
    {:ok,
     %{
       run
       | status: :blocked_waiting_for_user,
         question: question,
         updated_at: DateTime.utc_now()
     }}
  end

  def block_for_input(%__MODULE__{status: status}, _),
    do: {:error, {:invalid_transition, status, :blocked_waiting_for_user}}

  @doc "Resume a blocked run."
  @spec resume(t(), map() | nil) ::
          {:ok, t()} | {:error, {:invalid_transition, status(), :running}}
  def resume(run, answer \\ nil)

  def resume(%__MODULE__{status: s} = run, answer)
      when s in [:blocked, :blocked_waiting_for_user] do
    {:ok, %{run | status: :running, answer: answer, updated_at: DateTime.utc_now()}}
  end

  def resume(%__MODULE__{status: status}, _),
    do: {:error, {:invalid_transition, status, :running}}

  # ── Helpers ──────────────────────────────────────────────────────────

  @doc "Add a single artifact to the run's artifacts list."
  @spec add_artifact(t(), map()) :: t()
  def add_artifact(%__MODULE__{} = run, artifact) when is_map(artifact) do
    %{run | artifacts: run.artifacts ++ [artifact], updated_at: DateTime.utc_now()}
  end

  @doc "Add artifacts to the run."
  @spec add_artifacts(t(), [map()] | map()) :: t()
  def add_artifacts(%__MODULE__{} = run, new_artifacts) when is_list(new_artifacts) do
    %{run | artifacts: run.artifacts ++ new_artifacts, updated_at: DateTime.utc_now()}
  end

  def add_artifacts(%__MODULE__{} = run, new_artifacts) when is_map(new_artifacts) do
    # Backwards compat: merge map artifacts
    add_artifact(run, new_artifacts)
  end

  @doc "Add an assumption to the run."
  @spec add_assumption(t(), map()) :: t()
  def add_assumption(%__MODULE__{} = run, assumption) when is_map(assumption) do
    assumption = Map.put_new(assumption, :timestamp, DateTime.utc_now())
    %{run | assumptions: run.assumptions ++ [assumption], updated_at: DateTime.utc_now()}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp generate_id do
    "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
