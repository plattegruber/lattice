defmodule Lattice.Events.ReconciliationResult do
  @moduledoc """
  Event emitted after a Sprite reconciliation cycle completes.

  Reconciliation compares desired state with actual state and takes corrective
  action. Each cycle produces a result event with its outcome and timing.
  """

  @type t :: %__MODULE__{
          sprite_id: String.t(),
          outcome: :success | :failure | :no_change,
          duration_ms: non_neg_integer(),
          details: String.t() | nil,
          timestamp: DateTime.t()
        }

  @enforce_keys [:sprite_id, :outcome, :duration_ms, :timestamp]
  defstruct [:sprite_id, :outcome, :duration_ms, :details, :timestamp]

  @valid_outcomes [:success, :failure, :no_change]

  @doc """
  Creates a new ReconciliationResult event.

  ## Examples

      iex> Lattice.Events.ReconciliationResult.new("sprite-001", :success, 42)
      {:ok, %Lattice.Events.ReconciliationResult{sprite_id: "sprite-001", outcome: :success, duration_ms: 42, ...}}

  """
  @spec new(String.t(), atom(), non_neg_integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(sprite_id, outcome, duration_ms, opts \\ [])

  def new(sprite_id, outcome, duration_ms, opts) when outcome in @valid_outcomes do
    {:ok,
     %__MODULE__{
       sprite_id: sprite_id,
       outcome: outcome,
       duration_ms: duration_ms,
       details: Keyword.get(opts, :details),
       timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
     }}
  end

  def new(_sprite_id, outcome, _duration_ms, _opts) do
    {:error, {:invalid_outcome, outcome}}
  end

  @doc "Returns the list of valid reconciliation outcomes."
  @spec valid_outcomes() :: [atom()]
  def valid_outcomes, do: @valid_outcomes
end
