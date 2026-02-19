defmodule Lattice.Sprites.State do
  @moduledoc """
  Internal state struct for a Sprite GenServer process.

  Each Sprite GenServer holds a `%State{}` that tracks:

  - **Identity** -- `sprite_id` is the unique identifier for this Sprite
  - **Status** -- `status` is the current state from the API (`:cold`, `:warm`, `:running`)
  - **Backoff** -- exponential backoff parameters for retry after failure
  - **Failure tracking** -- `failure_count` tracks consecutive failures
  - **Log cursor** -- `log_cursor` tracks the last-read log position

  ## Statuses

  Sprites have three statuses matching the Sprites API:

      cold | warm | running
  """

  @type status :: :cold | :warm | :running

  @type t :: %__MODULE__{
          sprite_id: String.t(),
          name: String.t() | nil,
          status: status(),
          backoff_ms: non_neg_integer(),
          max_backoff_ms: non_neg_integer(),
          base_backoff_ms: non_neg_integer(),
          failure_count: non_neg_integer(),
          not_found_count: non_neg_integer(),
          max_retries: non_neg_integer(),
          last_observed_at: DateTime.t() | nil,
          api_created_at: DateTime.t() | nil,
          api_updated_at: DateTime.t() | nil,
          last_started_at: DateTime.t() | nil,
          last_active_at: DateTime.t() | nil,
          log_cursor: String.t() | nil,
          tags: map(),
          started_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @enforce_keys [:sprite_id, :started_at, :updated_at]
  defstruct [
    :sprite_id,
    :name,
    :log_cursor,
    :started_at,
    :updated_at,
    :last_observed_at,
    :api_created_at,
    :api_updated_at,
    :last_started_at,
    :last_active_at,
    status: :cold,
    backoff_ms: 1_000,
    max_backoff_ms: 60_000,
    base_backoff_ms: 1_000,
    failure_count: 0,
    not_found_count: 0,
    max_retries: 10,
    tags: %{}
  ]

  @valid_statuses [:cold, :warm, :running]

  @doc """
  Creates a new State struct for a Sprite.

  ## Options

  - `:status` -- initial status (default: `:cold`)
  - `:base_backoff_ms` -- base backoff interval in ms (default: 1000)
  - `:max_backoff_ms` -- maximum backoff interval in ms (default: 60000)
  - `:max_retries` -- maximum consecutive failures (default: 10)

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001")
      iex> state.sprite_id
      "sprite-001"
      iex> state.status
      :cold

  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(sprite_id, opts \\ []) when is_binary(sprite_id) do
    name = Keyword.get(opts, :name)
    status = Keyword.get(opts, :status, :cold)
    base_backoff = Keyword.get(opts, :base_backoff_ms, 1_000)
    max_backoff = Keyword.get(opts, :max_backoff_ms, 60_000)
    max_retries = Keyword.get(opts, :max_retries, 10)
    tags = Keyword.get(opts, :tags, %{})

    with :ok <- validate_status(status) do
      now = DateTime.utc_now()

      {:ok,
       %__MODULE__{
         sprite_id: sprite_id,
         name: name,
         status: status,
         base_backoff_ms: base_backoff,
         backoff_ms: base_backoff,
         max_backoff_ms: max_backoff,
         max_retries: max_retries,
         tags: tags,
         started_at: now,
         updated_at: now
       }}
    end
  end

  @doc """
  Update the status, updating the timestamp.

  Returns `{:ok, updated_state}` if the new status is valid, or
  `{:error, {:invalid_status, status}}` if it is not.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001")
      iex> {:ok, state} = Lattice.Sprites.State.update_status(state, :warm)
      iex> state.status
      :warm

  """
  @spec update_status(t(), status()) :: {:ok, t()} | {:error, term()}
  def update_status(%__MODULE__{} = state, new_status) do
    with :ok <- validate_status(new_status) do
      {:ok, %{state | status: new_status, updated_at: DateTime.utc_now()}}
    end
  end

  @doc """
  Record a failure, incrementing the counter and computing the next backoff.

  Uses exponential backoff: `min(base * 2^failures, max_backoff)`.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001", base_backoff_ms: 100, max_backoff_ms: 1000)
      iex> state = Lattice.Sprites.State.record_failure(state)
      iex> state.failure_count
      1
      iex> state.backoff_ms
      200

  """
  @spec record_failure(t()) :: t()
  def record_failure(%__MODULE__{} = state) do
    new_count = state.failure_count + 1
    new_backoff = compute_backoff(state.base_backoff_ms, new_count, state.max_backoff_ms)

    %{state | failure_count: new_count, backoff_ms: new_backoff, updated_at: DateTime.utc_now()}
  end

  @doc """
  Reset failure tracking after a successful operation.

  Resets `failure_count` to 0 and `backoff_ms` to `base_backoff_ms`.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001", base_backoff_ms: 100)
      iex> state = Lattice.Sprites.State.record_failure(state)
      iex> state = Lattice.Sprites.State.reset_backoff(state)
      iex> state.failure_count
      0
      iex> state.backoff_ms
      100

  """
  @spec reset_backoff(t()) :: t()
  def reset_backoff(%__MODULE__{} = state) do
    %{state | failure_count: 0, backoff_ms: state.base_backoff_ms, updated_at: DateTime.utc_now()}
  end

  @doc """
  Set the tags map, replacing the current tags entirely.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001")
      iex> state = Lattice.Sprites.State.set_tags(state, %{"env" => "prod"})
      iex> state.tags
      %{"env" => "prod"}

  """
  @spec set_tags(t(), map()) :: t()
  def set_tags(%__MODULE__{} = state, tags) when is_map(tags) do
    %{state | tags: tags, updated_at: DateTime.utc_now()}
  end

  @doc """
  Update the last observed timestamp after a successful API observation.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001")
      iex> state = Lattice.Sprites.State.record_observation(state)
      iex> state.last_observed_at != nil
      true

  """
  @spec record_observation(t()) :: t()
  def record_observation(%__MODULE__{} = state) do
    %{state | last_observed_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}
  end

  @doc """
  Store API-reported timestamps from the Sprites API response.

  Accepts a map with string keys matching the API response shape:
  `"created_at"`, `"updated_at"`, `"last_started_at"`, `"last_active_at"`.
  Ignores any keys that are `nil` or missing from the map.
  """
  @spec update_api_timestamps(t(), map()) :: t()
  def update_api_timestamps(%__MODULE__{} = state, api_data) when is_map(api_data) do
    %{
      state
      | api_created_at: parse_api_datetime(api_data["created_at"]) || state.api_created_at,
        api_updated_at: parse_api_datetime(api_data["updated_at"]) || state.api_updated_at,
        last_started_at: parse_api_datetime(api_data["last_started_at"]) || state.last_started_at,
        last_active_at: parse_api_datetime(api_data["last_active_at"]) || state.last_active_at
    }
  end

  @doc """
  Returns the display name for a Sprite: the human-readable name if set,
  otherwise falls back to the sprite_id.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name}) when is_binary(name), do: name
  def display_name(%__MODULE__{sprite_id: id}), do: id

  @doc """
  Compute the backoff delay with jitter for the next retry.

  Uses exponential backoff with random jitter of +/- 25% to prevent
  thundering-herd effects when multiple Sprites retry simultaneously.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001", base_backoff_ms: 1000)
      iex> state = Lattice.Sprites.State.record_failure(state)
      iex> delay = Lattice.Sprites.State.backoff_with_jitter(state)
      iex> delay >= 750 and delay <= 1250
      true

  """
  @spec backoff_with_jitter(t()) :: non_neg_integer()
  def backoff_with_jitter(%__MODULE__{backoff_ms: backoff}) do
    jitter_range = max(div(backoff, 4), 1)
    jitter = :rand.uniform(jitter_range * 2 + 1) - jitter_range - 1
    max(backoff + jitter, 0)
  end

  @doc "Returns the list of valid statuses."
  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses

  # ── Private ────────────────────────────────────────────────────────

  defp validate_status(status) when status in @valid_statuses, do: :ok
  defp validate_status(status), do: {:error, {:invalid_status, status}}

  defp compute_backoff(base, failure_count, max) do
    # Exponential backoff: base * 2^(failures - 1), capped at max
    backoff = base * Integer.pow(2, failure_count - 1)
    min(backoff, max)
  end

  defp parse_api_datetime(nil), do: nil

  defp parse_api_datetime(%DateTime{} = dt), do: dt

  defp parse_api_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_api_datetime(_), do: nil
end
