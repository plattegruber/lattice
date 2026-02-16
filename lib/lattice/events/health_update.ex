defmodule Lattice.Events.HealthUpdate do
  @moduledoc """
  Event emitted when a Sprite health check completes.

  Health checks are periodic probes that verify a Sprite is responsive and
  functioning correctly. Results flow through the event system to update
  the dashboard in real time.
  """

  @type t :: %__MODULE__{
          sprite_id: String.t(),
          status: :healthy | :degraded | :unhealthy,
          check_duration_ms: non_neg_integer(),
          message: String.t() | nil,
          timestamp: DateTime.t()
        }

  @enforce_keys [:sprite_id, :status, :check_duration_ms, :timestamp]
  defstruct [:sprite_id, :status, :check_duration_ms, :message, :timestamp]

  @valid_statuses [:healthy, :degraded, :unhealthy]

  @doc """
  Creates a new HealthUpdate event.

  ## Examples

      iex> Lattice.Events.HealthUpdate.new("sprite-001", :healthy, 15)
      {:ok, %Lattice.Events.HealthUpdate{sprite_id: "sprite-001", status: :healthy, check_duration_ms: 15, ...}}

  """
  @spec new(String.t(), atom(), non_neg_integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(sprite_id, status, check_duration_ms, opts \\ [])

  def new(sprite_id, status, check_duration_ms, opts) when status in @valid_statuses do
    {:ok,
     %__MODULE__{
       sprite_id: sprite_id,
       status: status,
       check_duration_ms: check_duration_ms,
       message: Keyword.get(opts, :message),
       timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
     }}
  end

  def new(_sprite_id, status, _check_duration_ms, _opts) do
    {:error, {:invalid_status, status}}
  end

  @doc "Returns the list of valid health statuses."
  @spec valid_statuses() :: [atom()]
  def valid_statuses, do: @valid_statuses
end
