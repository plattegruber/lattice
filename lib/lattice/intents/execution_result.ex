defmodule Lattice.Intents.ExecutionResult do
  @moduledoc """
  The outcome of executing an approved intent.

  Every executor returns an `%ExecutionResult{}` that captures what happened,
  how long it took, and any artifacts produced. The result is stored on the
  intent record for audit and debugging.

  ## Fields

  - `:status` -- `:success` or `:failure`
  - `:output` -- free-form output from the executor (e.g., API response)
  - `:error` -- error details when status is `:failure`
  - `:artifacts` -- list of artifact maps produced during execution
  - `:duration_ms` -- wall-clock execution time in milliseconds
  - `:started_at` -- when execution began
  - `:completed_at` -- when execution finished
  - `:executor` -- which executor module ran this intent
  """

  @type status :: :success | :failure

  @type t :: %__MODULE__{
          status: status(),
          output: term(),
          error: term(),
          artifacts: [map()],
          duration_ms: non_neg_integer(),
          started_at: DateTime.t(),
          completed_at: DateTime.t(),
          executor: module() | nil
        }

  @enforce_keys [:status, :duration_ms, :started_at, :completed_at]
  defstruct [
    :status,
    :duration_ms,
    :started_at,
    :completed_at,
    :executor,
    output: nil,
    error: nil,
    artifacts: []
  ]

  @valid_statuses [:success, :failure]

  # ── Constructors ─────────────────────────────────────────────────────

  @doc """
  Create a successful execution result.

  ## Options

  - `:output` -- execution output (default: `nil`)
  - `:artifacts` -- list of artifact maps (default: `[]`)
  - `:executor` -- executor module that ran the intent
  """
  @spec success(non_neg_integer(), DateTime.t(), DateTime.t(), keyword()) :: {:ok, t()}
  def success(duration_ms, started_at, completed_at, opts \\ [])
      when is_integer(duration_ms) and duration_ms >= 0 do
    {:ok,
     %__MODULE__{
       status: :success,
       output: Keyword.get(opts, :output),
       artifacts: Keyword.get(opts, :artifacts, []),
       duration_ms: duration_ms,
       started_at: started_at,
       completed_at: completed_at,
       executor: Keyword.get(opts, :executor)
     }}
  end

  @doc """
  Create a failed execution result.

  ## Options

  - `:error` -- error details (default: `nil`)
  - `:output` -- any partial output before failure (default: `nil`)
  - `:artifacts` -- any artifacts produced before failure (default: `[]`)
  - `:executor` -- executor module that ran the intent
  """
  @spec failure(non_neg_integer(), DateTime.t(), DateTime.t(), keyword()) :: {:ok, t()}
  def failure(duration_ms, started_at, completed_at, opts \\ [])
      when is_integer(duration_ms) and duration_ms >= 0 do
    {:ok,
     %__MODULE__{
       status: :failure,
       error: Keyword.get(opts, :error),
       output: Keyword.get(opts, :output),
       artifacts: Keyword.get(opts, :artifacts, []),
       duration_ms: duration_ms,
       started_at: started_at,
       completed_at: completed_at,
       executor: Keyword.get(opts, :executor)
     }}
  end

  @doc "Returns the list of valid result statuses."
  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses

  @doc "Returns `true` if the result represents a successful execution."
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{status: :success}), do: true
  def success?(%__MODULE__{}), do: false
end
