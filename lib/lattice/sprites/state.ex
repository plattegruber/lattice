defmodule Lattice.Sprites.State do
  @moduledoc """
  Internal state struct for a Sprite GenServer process.

  Each Sprite GenServer holds a `%State{}` that tracks:

  - **Identity** -- `sprite_id` is the unique identifier for this Sprite
  - **Lifecycle** -- `observed_state` is the current state from the API;
    `desired_state` is what the operator wants
  - **Health** -- `health` summarizes the last health check result
  - **Backoff** -- exponential backoff parameters for retry after failure
  - **Failure tracking** -- `failure_count` tracks consecutive failures
  - **Log cursor** -- `log_cursor` tracks the last-read log position

  ## Lifecycle States

  A Sprite moves through these states:

      hibernating -> waking -> ready -> busy -> error

  The `observed_state` reflects the actual state reported by the Sprites API.
  The `desired_state` is the target set by the operator. The reconciliation
  loop works to bring `observed_state` in line with `desired_state`.
  """

  @type lifecycle :: :hibernating | :waking | :ready | :busy | :error

  @type health :: :ok | :converging | :degraded | :error

  @type t :: %__MODULE__{
          sprite_id: String.t(),
          name: String.t() | nil,
          observed_state: lifecycle(),
          desired_state: lifecycle(),
          health: :healthy | :degraded | :unhealthy | :unknown | health(),
          backoff_ms: non_neg_integer(),
          max_backoff_ms: non_neg_integer(),
          base_backoff_ms: non_neg_integer(),
          failure_count: non_neg_integer(),
          max_retries: non_neg_integer(),
          last_observed_at: DateTime.t() | nil,
          log_cursor: String.t() | nil,
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
    observed_state: :hibernating,
    desired_state: :hibernating,
    health: :unknown,
    backoff_ms: 1_000,
    max_backoff_ms: 60_000,
    base_backoff_ms: 1_000,
    failure_count: 0,
    max_retries: 10
  ]

  @valid_lifecycle_states [:hibernating, :waking, :ready, :busy, :error]

  @doc """
  Creates a new State struct for a Sprite.

  ## Options

  - `:desired_state` -- initial desired state (default: `:hibernating`)
  - `:observed_state` -- initial observed state (default: `:hibernating`)
  - `:base_backoff_ms` -- base backoff interval in ms (default: 1000)
  - `:max_backoff_ms` -- maximum backoff interval in ms (default: 60000)
  - `:max_retries` -- maximum consecutive failures before health is `:error` (default: 10)

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001")
      iex> state.sprite_id
      "sprite-001"
      iex> state.observed_state
      :hibernating

  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(sprite_id, opts \\ []) when is_binary(sprite_id) do
    name = Keyword.get(opts, :name)
    desired = Keyword.get(opts, :desired_state, :hibernating)
    observed = Keyword.get(opts, :observed_state, :hibernating)
    base_backoff = Keyword.get(opts, :base_backoff_ms, 1_000)
    max_backoff = Keyword.get(opts, :max_backoff_ms, 60_000)
    max_retries = Keyword.get(opts, :max_retries, 10)

    with :ok <- validate_lifecycle(desired),
         :ok <- validate_lifecycle(observed) do
      now = DateTime.utc_now()

      {:ok,
       %__MODULE__{
         sprite_id: sprite_id,
         name: name,
         observed_state: observed,
         desired_state: desired,
         base_backoff_ms: base_backoff,
         backoff_ms: base_backoff,
         max_backoff_ms: max_backoff,
         max_retries: max_retries,
         started_at: now,
         updated_at: now
       }}
    end
  end

  @doc """
  Transition the observed state, updating the timestamp.

  Returns `{:ok, updated_state}` if the new state is valid, or
  `{:error, {:invalid_lifecycle, state}}` if it is not.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001")
      iex> {:ok, state} = Lattice.Sprites.State.transition(state, :waking)
      iex> state.observed_state
      :waking

  """
  @spec transition(t(), lifecycle()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{} = state, new_observed) do
    with :ok <- validate_lifecycle(new_observed) do
      {:ok, %{state | observed_state: new_observed, updated_at: DateTime.utc_now()}}
    end
  end

  @doc """
  Set the desired state, updating the timestamp.

  Returns `{:ok, updated_state}` if the new state is valid, or
  `{:error, {:invalid_lifecycle, state}}` if it is not.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001")
      iex> {:ok, state} = Lattice.Sprites.State.set_desired(state, :ready)
      iex> state.desired_state
      :ready

  """
  @spec set_desired(t(), lifecycle()) :: {:ok, t()} | {:error, term()}
  def set_desired(%__MODULE__{} = state, new_desired) do
    with :ok <- validate_lifecycle(new_desired) do
      {:ok, %{state | desired_state: new_desired, updated_at: DateTime.utc_now()}}
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
  Returns true if the observed state differs from the desired state.

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001", desired_state: :ready)
      iex> Lattice.Sprites.State.needs_reconciliation?(state)
      true

  """
  @spec needs_reconciliation?(t()) :: boolean()
  def needs_reconciliation?(%__MODULE__{observed_state: same, desired_state: same}), do: false
  def needs_reconciliation?(%__MODULE__{}), do: true

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
  Returns the display name for a Sprite: the human-readable name if set,
  otherwise falls back to the sprite_id.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name}) when is_binary(name), do: name
  def display_name(%__MODULE__{sprite_id: id}), do: id

  @doc """
  Compute health summary based on current state.

  Returns:
  - `:ok` -- observed matches desired, no failures
  - `:converging` -- action taken, waiting for effect (observed != desired, no failures)
  - `:degraded` -- retrying after failure (failure_count > 0 but under max_retries)
  - `:error` -- max retries exceeded or persistent failure

  ## Examples

      iex> {:ok, state} = Lattice.Sprites.State.new("sprite-001")
      iex> Lattice.Sprites.State.compute_health(state)
      :ok

  """
  @spec compute_health(t()) :: health()
  def compute_health(%__MODULE__{failure_count: count, max_retries: max})
      when count >= max do
    :error
  end

  def compute_health(%__MODULE__{failure_count: count}) when count > 0 do
    :degraded
  end

  def compute_health(%__MODULE__{observed_state: same, desired_state: same}) do
    :ok
  end

  def compute_health(%__MODULE__{}) do
    :converging
  end

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

  @doc "Returns the list of valid lifecycle states."
  @spec valid_lifecycle_states() :: [lifecycle()]
  def valid_lifecycle_states, do: @valid_lifecycle_states

  # ── Private ────────────────────────────────────────────────────────

  defp validate_lifecycle(state) when state in @valid_lifecycle_states, do: :ok
  defp validate_lifecycle(state), do: {:error, {:invalid_lifecycle, state}}

  defp compute_backoff(base, failure_count, max) do
    # Exponential backoff: base * 2^(failures - 1), capped at max
    backoff = base * Integer.pow(2, failure_count - 1)
    min(backoff, max)
  end
end
