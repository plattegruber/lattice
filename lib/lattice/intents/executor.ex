defmodule Lattice.Intents.Executor do
  @moduledoc """
  Behaviour for intent executors.

  Executors fulfill approved intents and report outcomes. They do not invent
  work. They do not negotiate scope. They report success, failure, and artifacts.

  The contract is simple and uniform regardless of executor type:

      execute(intent) :: {:ok, ExecutionResult.t()} | {:error, term()}

  Executor type is an implementation detail. Sprites are the primary executor,
  but some intents (infrastructure changes, direct API calls) may be fulfilled
  by the control plane itself. The behaviour boundary keeps this extensible.

  ## Implementations

  - `Lattice.Intents.Executor.Task` -- runs tasks on sprites via exec API (PR creation, etc.)
  - `Lattice.Intents.Executor.Sprite` -- routes to Sprite process via capabilities
  - `Lattice.Intents.Executor.ControlPlane` -- executes directly in the control plane
  """

  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Intent

  @doc """
  Execute an approved intent and return the outcome.

  The intent must be in `:approved` or `:running` state. The executor should
  invoke the appropriate capability and return an `ExecutionResult` capturing
  what happened.

  Returns `{:ok, result}` on both success and handled failure (the result's
  `status` field distinguishes them). Returns `{:error, reason}` only for
  executor-level errors (e.g., intent not executable, capability not found).
  """
  @callback execute(Intent.t()) :: {:ok, ExecutionResult.t()} | {:error, term()}

  @doc """
  Returns `true` if this executor can handle the given intent.

  Used by the Router to select the appropriate executor.
  """
  @callback can_execute?(Intent.t()) :: boolean()
end
