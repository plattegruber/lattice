defmodule Lattice.Intents.Observation do
  @moduledoc """
  A structured fact emitted by a Sprite about the world.

  Observations represent reality without side effects: "disk usage rising",
  "tests flaky", "build time increasing". They feed the Intent pipeline by
  generating proposals when conditions warrant action, but they do not
  execute anything themselves.

  > *Sprites surface reality. The control plane decides action.*

  ## Types

  - `:metric` — quantitative measurement (CPU, memory, latency, build time)
  - `:anomaly` — something unexpected or abnormal detected
  - `:status` — current state or health of a resource
  - `:recommendation` — a suggested improvement or action

  ## Severity

  Severity indicates how urgently the observation warrants attention:

  - `:info` — informational, no action needed
  - `:low` — minor concern, low priority
  - `:medium` — moderate concern, should be addressed
  - `:high` — significant concern, needs attention soon
  - `:critical` — urgent, may generate an intent automatically
  """

  @valid_types [:metric, :anomaly, :status, :recommendation]
  @valid_severities [:info, :low, :medium, :high, :critical]

  @type observation_type :: :metric | :anomaly | :status | :recommendation
  @type severity :: :info | :low | :medium | :high | :critical

  @type t :: %__MODULE__{
          id: String.t(),
          sprite_id: String.t(),
          type: observation_type(),
          data: map(),
          severity: severity(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:id, :sprite_id, :type, :data, :severity, :timestamp]
  defstruct [:id, :sprite_id, :type, :data, :severity, :timestamp]

  @doc """
  Creates a new Observation.

  ## Options

  - `:data` — observation payload (default: `%{}`)
  - `:severity` — severity level (default: `:info`)
  - `:timestamp` — override timestamp (default: `DateTime.utc_now()`)

  ## Examples

      iex> Lattice.Intents.Observation.new("sprite-001", :metric, data: %{"cpu" => 85.2}, severity: :medium)
      {:ok, %Lattice.Intents.Observation{sprite_id: "sprite-001", type: :metric, ...}}

  """
  @spec new(String.t(), observation_type(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(sprite_id, type, opts \\ [])

  def new(sprite_id, type, opts) when is_binary(sprite_id) and type in @valid_types do
    severity = Keyword.get(opts, :severity, :info)

    if severity in @valid_severities do
      {:ok,
       %__MODULE__{
         id: generate_id(),
         sprite_id: sprite_id,
         type: type,
         data: Keyword.get(opts, :data, %{}),
         severity: severity,
         timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
       }}
    else
      {:error, {:invalid_severity, severity}}
    end
  end

  def new(_sprite_id, type, _opts) when type not in @valid_types do
    {:error, {:invalid_type, type}}
  end

  def new(sprite_id, _type, _opts) when not is_binary(sprite_id) do
    {:error, {:invalid_sprite_id, sprite_id}}
  end

  @doc "Returns the list of valid observation types."
  @spec valid_types() :: [observation_type()]
  def valid_types, do: @valid_types

  @doc "Returns the list of valid severity levels."
  @spec valid_severities() :: [severity()]
  def valid_severities, do: @valid_severities

  defp generate_id do
    "obs_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
