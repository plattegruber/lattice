defmodule Lattice.Sprites.Sprite do
  @moduledoc """
  GenServer representing a single Sprite process.

  Each Sprite gets its own GenServer that:

  - Owns the Sprite's internal state (`%Lattice.Sprites.State{}`)
  - Runs a periodic reconciliation loop comparing desired vs. observed state
  - Fetches real observed state from the SpritesCapability API each cycle
  - Emits Telemetry events and PubSub broadcasts on state transitions
  - Implements exponential backoff with jitter on reconciliation failures
  - Computes and broadcasts health assessments after each reconciliation
  - Handles API edge cases: timeouts, not-found, concurrent changes

  ## Starting a Sprite

      Lattice.Sprites.Sprite.start_link(sprite_id: "sprite-001", desired_state: :ready)

  ## Querying State

      {:ok, state} = Lattice.Sprites.Sprite.get_state(pid)

  ## Changing Desired State

      :ok = Lattice.Sprites.Sprite.set_desired_state(pid, :ready)

  ## Reconciliation

  The reconciliation loop runs on a timer (default: 5 seconds). Each cycle:

  1. Calls `SpritesCapability.get_sprite/1` to fetch the real observed state
  2. Compares observed state against desired state
  3. If they differ, calls the appropriate capability to drive the transition
  4. Emits a `ReconciliationResult` event with the outcome
  5. Computes and broadcasts a health assessment
  6. On success, resets the backoff; on failure, applies exponential backoff with jitter
  """

  use GenServer

  require Logger

  alias Lattice.Events
  alias Lattice.Events.HealthUpdate
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Intents.IntentGenerator
  alias Lattice.Intents.Observation
  alias Lattice.Sprites.Logs
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
  - `:max_retries` -- max consecutive failures before health is `:error` (default: 10)
  - `:name` -- GenServer name registration (optional; when omitted and the
    `Lattice.Sprites.Registry` is running, the process registers itself via
    the Registry under `sprite_id`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    sprite_id = Keyword.fetch!(opts, :sprite_id)
    name = Keyword.get_lazy(opts, :name, fn -> via_registry(sprite_id) end)

    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, {sprite_id, opts}, gen_opts)
  end

  @doc """
  Returns the `{:via, Registry, ...}` tuple for a given sprite ID.

  Useful for addressing a Sprite process by its ID when the Registry is running.
  """
  @spec via(String.t()) :: {:via, Registry, {Lattice.Sprites.Registry, String.t()}}
  def via(sprite_id) when is_binary(sprite_id) do
    {:via, Registry, {Lattice.Sprites.Registry, sprite_id}}
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
  Set the tags map for a Sprite, replacing the current tags.

  Tags are Lattice-local metadata (not part of the Sprites API).
  Returns `:ok` on success.
  """
  @spec set_tags(GenServer.server(), map()) :: :ok
  def set_tags(server, tags) when is_map(tags) do
    GenServer.call(server, {:set_tags, tags})
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

  @doc """
  Emit an observation from this Sprite.

  Observations are structured facts about the world that the Sprite has
  noticed. They are broadcast via PubSub and may generate Intent proposals
  through the configured IntentGenerator.

  ## Options

  - `:type` (required) -- observation type (`:metric`, `:anomaly`, `:status`, `:recommendation`)
  - `:data` -- observation data map (default: `%{}`)
  - `:severity` -- severity level (default: `:info`)

  ## Returns

  - `{:ok, observation}` -- observation emitted, no intent generated
  - `{:ok, observation, intent}` -- observation emitted and intent generated
  - `{:error, reason}` -- invalid observation parameters
  """
  @spec emit_observation(GenServer.server(), keyword()) ::
          {:ok, Observation.t()}
          | {:ok, Observation.t(), Lattice.Intents.Intent.t()}
          | {:error, term()}
  def emit_observation(server, opts) do
    GenServer.call(server, {:emit_observation, opts})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init({sprite_id, opts}) do
    state_opts = [
      name: Keyword.get(opts, :sprite_name),
      desired_state: Keyword.get(opts, :desired_state, :hibernating),
      observed_state: Keyword.get(opts, :observed_state, :hibernating),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, 1_000),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, 60_000),
      max_retries: Keyword.get(opts, :max_retries, 10),
      tags: Keyword.get(opts, :tags, %{})
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

  def handle_call({:set_tags, tags}, _from, {state, interval}) do
    new_state = State.set_tags(state, tags)
    {:reply, :ok, {new_state, interval}}
  end

  def handle_call({:emit_observation, opts}, _from, {state, interval}) do
    type = Keyword.fetch!(opts, :type)
    obs_opts = Keyword.drop(opts, [:type])

    case Observation.new(state.sprite_id, type, obs_opts) do
      {:ok, observation} ->
        Events.broadcast_observation(observation)

        case IntentGenerator.generate(observation) do
          {:ok, intent} ->
            {:reply, {:ok, observation, intent}, {state, interval}}

          :skip ->
            {:reply, {:ok, observation}, {state, interval}}

          {:error, _reason} ->
            {:reply, {:ok, observation}, {state, interval}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, {state, interval}}
    end
  end

  @impl true
  def handle_cast(:reconcile_now, {state, interval}) do
    case do_reconcile(state) do
      {:stop, reason, new_state} ->
        {:stop, reason, {new_state, interval}}

      {new_state, :not_found} ->
        schedule_reconcile(5_000)
        {:noreply, {new_state, interval}}

      {new_state, _outcome} ->
        schedule_reconcile(interval)
        {:noreply, {new_state, interval}}
    end
  end

  @impl true
  def handle_info(:reconcile, {state, interval}) do
    case do_reconcile(state) do
      {:stop, reason, new_state} ->
        {:stop, reason, {new_state, interval}}

      {new_state, :not_found} ->
        schedule_reconcile(5_000)
        {:noreply, {new_state, interval}}

      {new_state, _outcome} ->
        next_interval = reconcile_delay(new_state, interval)
        schedule_reconcile(next_interval)
        {:noreply, {new_state, interval}}
    end
  end

  # ── Reconciliation Logic ────────────────────────────────────────────

  defp do_reconcile(%State{} = state) do
    start_time = System.monotonic_time(:millisecond)

    case fetch_observed_state(state) do
      {:ok, api_observed} ->
        state = update_from_observation(state, api_observed)
        reconcile_with_observation(state, start_time)

      {:error, :not_found} ->
        handle_not_found(state, start_time)

      {:error, reason} ->
        handle_fetch_failure(state, reason, start_time)
    end
  end

  # Fetch the real observed state from the SpritesCapability API.
  defp fetch_observed_state(%State{sprite_id: sprite_id}) do
    case sprites_capability().get_sprite(sprite_id) do
      {:ok, %{status: status}} when is_atom(status) ->
        {:ok, status}

      {:ok, %{status: status}} when is_binary(status) ->
        {:ok, parse_api_status(status)}

      {:ok, _sprite_data} ->
        {:ok, :error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Map API string statuses to internal lifecycle atoms.
  defp parse_api_status("running"), do: :ready
  defp parse_api_status("cold"), do: :hibernating
  defp parse_api_status("warm"), do: :waking
  defp parse_api_status("sleeping"), do: :hibernating
  defp parse_api_status(_other), do: :error

  # Update internal state with the observed API snapshot.
  defp update_from_observation(%State{} = state, api_observed) do
    old_observed = state.observed_state

    case State.transition(state, api_observed) do
      {:ok, new_state} ->
        new_state = State.record_observation(new_state)

        if old_observed != api_observed do
          emit_state_change(
            state.sprite_id,
            old_observed,
            api_observed,
            "API observation"
          )
        end

        new_state

      {:error, _} ->
        state
    end
  end

  # After updating observed from the API, decide what action to take.
  defp reconcile_with_observation(%State{} = state, start_time) do
    if State.needs_reconciliation?(state) do
      reconcile_transition(state, start_time)
    else
      duration = System.monotonic_time(:millisecond) - start_time
      new_state = State.reset_backoff(state)
      new_state = %{new_state | not_found_count: 0}
      emit_reconciliation_result(new_state, :no_change, duration)
      new_state = update_and_emit_health(new_state, duration)
      {new_state, :no_change}
    end
  end

  defp reconcile_transition(%State{} = state, start_time) do
    case attempt_transition(state) do
      {:ok, new_observed} ->
        duration = System.monotonic_time(:millisecond) - start_time
        old_observed = state.observed_state

        {:ok, new_state} = State.transition(state, new_observed)
        new_state = State.reset_backoff(new_state)
        new_state = %{new_state | not_found_count: 0}
        new_state = State.record_observation(new_state)

        emit_state_change(state.sprite_id, old_observed, new_observed, "reconciliation")

        emit_reconciliation_result(
          new_state,
          :success,
          duration,
          "transitioned to #{new_observed}"
        )

        new_state = update_and_emit_health(new_state, duration)

        {new_state, :success}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        new_state = State.record_failure(state)

        new_state = maybe_transition_to_error(new_state, state.observed_state)

        emit_reconciliation_result(
          new_state,
          :failure,
          duration,
          "reconciliation failed: #{inspect(reason)}"
        )

        new_state = update_and_emit_health(new_state, duration)

        {new_state, :failure}
    end
  end

  # Handle the case where the sprite was not found in the API (removed externally).
  # Uses a two-strike approach: first not-found retries quickly, second consecutive
  # not-found confirms deletion and stops the GenServer gracefully.
  defp handle_not_found(%State{} = state, _start_time) do
    new_count = state.not_found_count + 1

    if new_count >= 2 do
      # Second consecutive not-found — sprite is truly gone
      Logger.warning(
        "Sprite #{state.sprite_id} confirmed deleted externally (#{new_count} consecutive not-found)"
      )

      :telemetry.execute(
        [:lattice, :sprite, :externally_deleted],
        %{count: 1},
        %{sprite_id: state.sprite_id, last_state: state.observed_state}
      )

      Phoenix.PubSub.broadcast(
        Lattice.PubSub,
        Events.fleet_topic(),
        {:sprite_externally_deleted, state.sprite_id}
      )

      {:stop, :normal, state}
    else
      # First not-found — could be transient, retry quickly
      Logger.warning(
        "Sprite #{state.sprite_id} not found in API (attempt #{new_count}/2), retrying...",
        sprite_id: state.sprite_id
      )

      new_state = %{state | not_found_count: new_count}
      {new_state, :not_found}
    end
  end

  # Handle API fetch failure (timeout, network error, etc.) as a transient failure.
  defp handle_fetch_failure(%State{} = state, reason, start_time) do
    duration = System.monotonic_time(:millisecond) - start_time
    old_observed = state.observed_state
    new_state = State.record_failure(state)
    new_state = %{new_state | not_found_count: 0}

    Logger.warning("Sprite reconciliation failure",
      sprite_id: state.sprite_id,
      reason: inspect(reason)
    )

    new_state = maybe_transition_to_error(new_state, old_observed)

    emit_reconciliation_result(
      new_state,
      :failure,
      duration,
      "API fetch failed: #{inspect(reason)}"
    )

    new_state = update_and_emit_health(new_state, duration)

    {new_state, :failure}
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
  # Calls the real SpritesCapability with the actual sprite_id.
  defp attempt_transition(%State{
         sprite_id: id,
         observed_state: :hibernating,
         desired_state: desired
       })
       when desired in [:waking, :ready, :busy] do
    case sprites_capability().wake(id) do
      {:ok, _} -> {:ok, :waking}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{sprite_id: id, observed_state: :waking, desired_state: desired})
       when desired in [:ready, :busy] do
    # Check if waking has completed
    case sprites_capability().get_sprite(id) do
      {:ok, %{status: status}} -> {:ok, resolve_observed(status)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{
         sprite_id: id,
         observed_state: :waking,
         desired_state: :hibernating
       }) do
    case sprites_capability().sleep(id) do
      {:ok, _} -> {:ok, :hibernating}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{sprite_id: id, observed_state: :ready, desired_state: :busy}) do
    case sprites_capability().exec(id, "start-task") do
      {:ok, _} -> {:ok, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{
         sprite_id: id,
         observed_state: :ready,
         desired_state: :hibernating
       }) do
    case sprites_capability().sleep(id) do
      {:ok, _} -> {:ok, :hibernating}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{sprite_id: id, observed_state: :busy, desired_state: :ready}) do
    # Busy -> ready happens when the task completes; check the API
    case sprites_capability().get_sprite(id) do
      {:ok, %{status: status}} -> {:ok, resolve_observed(status)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{
         sprite_id: id,
         observed_state: :busy,
         desired_state: :hibernating
       }) do
    case sprites_capability().sleep(id) do
      {:ok, _} -> {:ok, :ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{
         sprite_id: id,
         observed_state: :error,
         desired_state: :hibernating
       }) do
    # Recovery to hibernating: sleep the sprite
    case sprites_capability().sleep(id) do
      {:ok, _} -> {:ok, :hibernating}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{sprite_id: id, observed_state: :error, desired_state: desired})
       when desired in [:waking, :ready] do
    # Recovery from error: wake the sprite
    case sprites_capability().wake(id) do
      {:ok, _} -> {:ok, :waking}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_transition(%State{observed_state: observed, desired_state: desired}) do
    {:error, {:no_transition_path, from: observed, to: desired}}
  end

  # Resolve a status value (atom or string) from the API response to a lifecycle atom.
  defp resolve_observed(status) when is_atom(status), do: status
  defp resolve_observed(status) when is_binary(status), do: parse_api_status(status)

  # ── Health Assessment ─────────────────────────────────────────────

  defp update_and_emit_health(%State{} = state, duration_ms) do
    new_health = State.compute_health(state)
    old_health = state.health

    new_state = %{state | health: new_health}

    if old_health != new_health do
      emit_health_update(new_state, new_health, duration_ms)
    end

    new_state
  end

  # ── Event Emission ──────────────────────────────────────────────────

  defp emit_state_change(sprite_id, from, to, reason) do
    case StateChange.new(sprite_id, from, to, reason: reason) do
      {:ok, event} -> Events.broadcast_state_change(event)
      {:error, _} -> :ok
    end

    log_line = Logs.from_event(:state_change, sprite_id, %{from: from, to: to, reason: reason})
    Events.broadcast_sprite_log(sprite_id, log_line)
  end

  defp emit_reconciliation_result(state, outcome, duration_ms, details \\ nil) do
    opts = if details, do: [details: details], else: []

    case ReconciliationResult.new(state.sprite_id, outcome, duration_ms, opts) do
      {:ok, event} -> Events.broadcast_reconciliation_result(event)
      {:error, _} -> :ok
    end

    log_line =
      Logs.from_event(:reconciliation, state.sprite_id, %{
        outcome: outcome,
        duration_ms: duration_ms,
        details: details
      })

    Events.broadcast_sprite_log(state.sprite_id, log_line)
  end

  defp emit_health_update(%State{} = state, health_status, duration_ms) do
    # Map internal health atoms to HealthUpdate-compatible statuses
    status = health_to_event_status(health_status)
    message = health_message(health_status, state)

    case HealthUpdate.new(state.sprite_id, status, duration_ms, message: message) do
      {:ok, event} -> Events.broadcast_health_update(event)
      {:error, _} -> :ok
    end

    log_line =
      Logs.from_event(:health, state.sprite_id, %{status: status, message: message})

    Events.broadcast_sprite_log(state.sprite_id, log_line)
  end

  defp health_to_event_status(:ok), do: :healthy
  defp health_to_event_status(:converging), do: :healthy
  defp health_to_event_status(:degraded), do: :degraded
  defp health_to_event_status(:error), do: :unhealthy

  defp health_message(:ok, _state), do: "observed matches desired"
  defp health_message(:converging, _state), do: "action taken, waiting for effect"

  defp health_message(:degraded, %State{failure_count: count}),
    do: "retrying after #{count} consecutive failure(s)"

  defp health_message(:error, %State{failure_count: count, max_retries: max}),
    do: "max retries exceeded (#{count}/#{max})"

  # ── Scheduling ──────────────────────────────────────────────────────

  defp schedule_reconcile(interval_ms) do
    Process.send_after(self(), :reconcile, interval_ms)
  end

  defp reconcile_delay(%State{failure_count: 0}, interval), do: interval
  defp reconcile_delay(%State{} = state, _interval), do: State.backoff_with_jitter(state)

  # ── Registry ────────────────────────────────────────────────────────

  defp via_registry(sprite_id) do
    if registry_running?() do
      via(sprite_id)
    else
      nil
    end
  end

  defp registry_running? do
    Process.whereis(Lattice.Sprites.Registry) != nil
  end

  # ── Capability Access ───────────────────────────────────────────────

  defp sprites_capability do
    Application.get_env(:lattice, :capabilities)[:sprites]
  end
end
