defmodule Lattice.Events.StateChange do
  @moduledoc """
  Event emitted when a Sprite transitions between statuses.

  Sprites have three statuses: `cold`, `warm`, `running`.

  Each transition produces a `StateChange` event that flows through both
  Telemetry (for metrics/logging) and PubSub (for real-time fan-out to
  LiveView processes).
  """

  @type t :: %__MODULE__{
          sprite_id: String.t(),
          from_state: atom(),
          to_state: atom(),
          reason: String.t() | nil,
          timestamp: DateTime.t()
        }

  @enforce_keys [:sprite_id, :from_state, :to_state, :timestamp]
  defstruct [:sprite_id, :from_state, :to_state, :reason, :timestamp]

  @valid_states [:cold, :warm, :running]

  @doc """
  Creates a new StateChange event.

  ## Examples

      iex> Lattice.Events.StateChange.new("sprite-001", :hibernating, :waking)
      {:ok, %Lattice.Events.StateChange{sprite_id: "sprite-001", from_state: :hibernating, to_state: :waking, ...}}

  """
  @spec new(String.t(), atom(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(sprite_id, from_state, to_state, opts \\ []) do
    with :ok <- validate_state(from_state),
         :ok <- validate_state(to_state) do
      {:ok,
       %__MODULE__{
         sprite_id: sprite_id,
         from_state: from_state,
         to_state: to_state,
         reason: Keyword.get(opts, :reason),
         timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
       }}
    end
  end

  @doc "Returns the list of valid Sprite states."
  @spec valid_states() :: [atom()]
  def valid_states, do: @valid_states

  defp validate_state(state) when state in @valid_states, do: :ok
  defp validate_state(state), do: {:error, {:invalid_state, state}}
end
