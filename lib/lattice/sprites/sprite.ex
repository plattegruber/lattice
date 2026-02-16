defmodule Lattice.Sprites.Sprite do
  @moduledoc """
  GenServer representing a single Sprite process.

  Each Sprite gets its own GenServer that:

  - Owns the Sprite's internal state (`%Lattice.Sprites.State{}`)
  - Runs a periodic reconciliation loop comparing desired vs. observed state
  - Emits Telemetry events and PubSub broadcasts on state transitions
  - Implements exponential backoff on reconciliation failures
  - Resets backoff counters on successful reconciliation

  ## Starting a Sprite

      Lattice.Sprites.Sprite.start_link(sprite_id: "sprite-001", desired_state: :ready)

  ## Querying State

      {:ok, state} = Lattice.Sprites.Sprite.get_state(pid)

  ## Changing Desired State

      :ok = Lattice.Sprites.Sprite.set_desired_state(pid, :ready)

  ## Reconciliation

  The reconciliation loop runs on a timer (default: 5 seconds). Each cycle:

  1. Compares `observed_state` to `desired_state`
  2. If they differ, calls the appropriate capability to drive the transition
  3. Emits a `ReconciliationResult` event with the outcome
  4. On success, resets the backoff; on failure, applies exponential backoff

  Reconciliation uses stub capabilities — no real API calls are made until
  the real Sprites API integration in Step 2.
  """

  use GenServer

  alias Lattice.Events
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Sprites.State

  @default_reconcile_interval_ms 5_000

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start a Sprite GenServer process.

  ## Options

  - `:sprite_id` (required) -- unique identifier for this Sprite
  - `:desired_state` -- initial desired state (default: `:hibernating`)
  - `:observed_state` -- initial observed state (default: `:hibernating`)
  - `:reconcile_interval_ms` -- reconciliation loop interval (default: 5000)
  - `:base_backoff_ms` -- base backoff for retries (default: 1000)
  - `:max_backoff_ms` -- max backoff cap (default: 60000)
  - `:name` -- GenServer name registration (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    sprite_id = Keyword.fetch!(opts, :sprite_id)
    name = Keyword.get(opts, :name)

    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, {sprite_id, opts}, gen_opts)
  end

  @doc """
  Get the current state of a Sprite.

  Returns `{:ok, %State{}}` with the current internal state.
  """
  @spec get_state(GenServer.server()) :: {:ok, State.t()}
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Set the desired state for a Sprite.

  Triggers reconciliation on the next cycle. Returns `:ok` on success or
  `{:error, reason}` if the desired state is invalid.
  """
  @spec set_desired_state(GenServer.server(), State.lifecycle()) :: :ok | {:error, term()}
  def set_desired_state(server, desired_state) do
    GenServer.call(server, {:set_desired_state, desired_state})
  end

  @doc """
  Trigger an immediate reconciliation cycle.

  Useful for testing or when an operator wants to force a reconciliation
  without waiting for the next scheduled cycle.
  """
  @spec reconcile_now(GenServer.server()) :: :ok
  def reconcile_now(server) do
    GenServer.cast(server, :reconcile_now)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init({sprite_id, opts}) do
    state_opts = [
      desired_state: Keyword.get(opts, :desired_state, :hibernating),
      observed_state: Keyword.get(opts, :observed_state, :hibernating),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, 1_000),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, 60_000)
    ]

    reconcile_interval = Keyword.get(opts, :reconcile_interval_ms, @default_reconcile_interval_ms)

    case State.new(sprite_id, state_opts) do
      {:ok, state} ->
        schedule_reconcile(reconcile_interval)
        {:ok, {state, reconcile_interval}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, {state, _interval} = server_state) do
    {:reply, {:ok, state}, server_state}
  end

  def handle_call({:set_desired_state, desired}, _from, {state, interval}) do
    case State.set_desired(state, desired) do
      {:ok, new_state} ->
        {:reply, :ok, {new_state, interval}}

      {:error, _reason} = error ->
        {:reply, error, {state, interval}}
    end
  end

  @impl true
  def handle_cast(:reconcile_now, {state, interval}) do
    {new_state, _outcome} = do_reconcile(state)
    schedule_reconcile(interval)
    {:noreply, {new_state, interval}}
  end

  @impl true
  def handle_info(:reconcile, {state, interval}) do
    {new_state, _outcome} = do_reconcile(state)
    next_interval = reconcile_delay(new_state, interval)
    schedule_reconcile(next_interval)
    {:noreply, {new_state, interval}}
  end

  # ── Reconciliation Logic ────────────────────────────────────────────

  defp do_reconcile(%State{} = state) do
    start_time = System.monotonic_time(:millisecond)

    if State.needs_reconciliation?(state) do
      reconcile_transition(state, start_time)
    else
      emit_reconciliation_result(state, :no_change, 0)
      {state, :no_change}
    end
  end

  defp reconcile_transition(state, start_time) do
    case attempt_transition(state) do
      {:ok, new_observed} ->
        duration = System.monotonic_time(:millisecond) - start_time
        old_observed = state.observed_state

        {:ok, new_state} = State.transition(state, new_observed)
        new_state = State.reset_backoff(new_state)

        emit_state_change(state.sprite_id, old_observed, new_observed, "reconciliation")
        emit_reconciliation_result(state, :success, duration, "transitioned to #{new_observed}")

        {new_state, :success}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        new_state = State.record_failure(state)

        # Transition to error state if not already there
        new_state = maybe_transition_to_error(new_state, state.observed_state)

        emit_reconciliation_result(
          state,
          :failure,
          duration,
          "reconciliation failed: #{inspect(reason)}"
        )

        {new_state, :failure}
    end
  end

  defp maybe_transition_to_error(%State{} = state, previous_observed) do
    if previous_observed != :error do
      case State.transition(state, :error) do
        {:ok, error_state} ->
          emit_state_change(
            state.sprite_id,
            previous_observed,
            :error,
            "reconciliation failure"
          )

          error_state

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  # Determine what transition to attempt based on current and desired state.
  # Uses stub capabilities — returns synthetic results.
  defp attempt_transition(%State{observed_state: :hibernating, desired_state: desired})
       when desired in [:waking, :ready, :busy] do
    case sprites_capability().wake("synthetic") do
      {:ok, _} -> {:ok, :waking}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{observed_state: :waking, desired_state: desired})
       when desired in [:ready, :busy] do
    # Simulate the waking -> ready transition completing
    case sprites_capability().get_sprite("synthetic") do
      {:ok, _} -> {:ok, :ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{observed_state: :ready, desired_state: :busy}) do
    case sprites_capability().exec("synthetic", "start-task") do
      {:ok, _} -> {:ok, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{observed_state: :ready, desired_state: :hibernating}) do
    case sprites_capability().sleep("synthetic") do
      {:ok, _} -> {:ok, :hibernating}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{observed_state: :busy, desired_state: :ready}) do
    # Busy -> ready happens when the task completes
    case sprites_capability().get_sprite("synthetic") do
      {:ok, _} -> {:ok, :ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{observed_state: :busy, desired_state: :hibernating}) do
    case sprites_capability().sleep("synthetic") do
      {:ok, _} -> {:ok, :ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{observed_state: :error, desired_state: desired})
       when desired in [:hibernating, :waking, :ready] do
    # Attempt recovery from error state
    case sprites_capability().wake("synthetic") do
      {:ok, _} -> {:ok, :waking}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{observed_state: observed, desired_state: desired}) do
    {:error, {:no_transition_path, from: observed, to: desired}}
  end

  # ── Event Emission ──────────────────────────────────────────────────

  defp emit_state_change(sprite_id, from, to, reason) do
    case StateChange.new(sprite_id, from, to, reason: reason) do
      {:ok, event} -> Events.broadcast_state_change(event)
      {:error, _} -> :ok
    end
  end

  defp emit_reconciliation_result(state, outcome, duration_ms, details \\ nil) do
    opts = if details, do: [details: details], else: []

    case ReconciliationResult.new(state.sprite_id, outcome, duration_ms, opts) do
      {:ok, event} -> Events.broadcast_reconciliation_result(event)
      {:error, _} -> :ok
    end
  end

  # ── Scheduling ──────────────────────────────────────────────────────

  defp schedule_reconcile(interval_ms) do
    Process.send_after(self(), :reconcile, interval_ms)
  end

  defp reconcile_delay(%State{failure_count: 0}, interval), do: interval
  defp reconcile_delay(%State{backoff_ms: backoff}, _interval), do: backoff

  # ── Capability Access ───────────────────────────────────────────────

  defp sprites_capability do
    Application.get_env(:lattice, :capabilities)[:sprites]
  end
end
