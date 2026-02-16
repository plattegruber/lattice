defmodule Lattice.Safety.Action do
  @moduledoc """
  Represents a capability action with its safety classification.

  Every capability function maps to an Action that carries the capability name,
  the operation (function name), and its classification level. Actions are the
  input to the Gate module, which decides whether to allow or deny execution.

  ## Classification Levels

  - `:safe` -- read-only, no side effects (list sprites, get status, fetch logs)
  - `:controlled` -- state-mutating, requires approval (wake/sleep, deploy, exec)
  - `:dangerous` -- infrastructure-level, requires explicit opt-in + approval
    (destroy, scale, migrate)
  """

  @type classification :: :safe | :controlled | :dangerous

  @type t :: %__MODULE__{
          capability: atom(),
          operation: atom(),
          classification: classification()
        }

  @enforce_keys [:capability, :operation, :classification]
  defstruct [:capability, :operation, :classification]

  @valid_classifications [:safe, :controlled, :dangerous]

  @doc """
  Creates a new Action struct.

  Returns `{:ok, action}` if the classification is valid, or
  `{:error, {:invalid_classification, classification}}` otherwise.

  ## Examples

      iex> Lattice.Safety.Action.new(:sprites, :list_sprites, :safe)
      {:ok, %Lattice.Safety.Action{capability: :sprites, operation: :list_sprites, classification: :safe}}

  """
  @spec new(atom(), atom(), classification()) :: {:ok, t()} | {:error, term()}
  def new(capability, operation, classification)
      when classification in @valid_classifications do
    {:ok,
     %__MODULE__{
       capability: capability,
       operation: operation,
       classification: classification
     }}
  end

  def new(_capability, _operation, classification) do
    {:error, {:invalid_classification, classification}}
  end

  @doc "Returns the list of valid classification levels."
  @spec valid_classifications() :: [classification()]
  def valid_classifications, do: @valid_classifications
end
