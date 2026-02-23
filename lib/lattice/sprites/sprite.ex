defmodule Lattice.Sprites.Sprite do
  @moduledoc """
  GenServer representing a single Sprite process.

  Each Sprite gets its own GenServer that:

  - Owns the Sprite's internal state (`%Lattice.Sprites.State{}`)
  - Runs a periodic observation loop fetching status from the Sprites API
  - Emits Telemetry events and PubSub broadcasts on status changes
  - Implements exponential backoff with jitter on observation failures
  - Handles API edge cases: timeouts, not-found, concurrent changes

  ## Starting a Sprite

      Lattice.Sprites.Sprite.start_link(sprite_id: "sprite-001")

  ## Querying State

      {:ok, state} = Lattice.Sprites.Sprite.get_state(pid)

  ## Observation Loop

  The observation loop runs on a timer (default: 5 seconds). Each cycle:

  1. Calls `SpritesCapability.get_sprite/1` to fetch the real status
  2. Emits a `StateChange` event if the status changed
  3. On success, resets the backoff; on failure, applies exponential backoff with jitter
  """

  use GenServer

  require Logger

  alias Lattice.Events
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
  - `:status` -- initial status (default: `:cold`)
  - `:reconcile_interval_ms` -- observation loop interval (default: 5000)
  - `:base_backoff_ms` -- base backoff for retries (default: 1000)
  - `:max_backoff_ms` -- max backoff cap (default: 60000)
  - `:max_retries` -- max consecutive failures (default: 10)
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
  Set the tags map for a Sprite, replacing the current tags.

  Tags are Lattice-local metadata (not part of the Sprites API).
  Returns `:ok` on success.
  """
  @spec set_tags(GenServer.server(), map()) :: :ok
  def set_tags(server, tags) when is_map(tags) do
    GenServer.call(server, {:set_tags, tags})
  end

  @doc """
  Trigger an immediate observation cycle.

  Useful for testing or when an operator wants to force an observation
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

  @doc """
  Route a GitHub update event to this Sprite.

  Called when a webhook event (comment, code push, review) arrives for a
  GitHub work item already being handled by this Sprite process. The Sprite
  logs the update and may act on it in future iterations.

  Returns `:ok`.
  """
  @spec route_github_update(GenServer.server(), atom(), map()) :: :ok
  def route_github_update(server, kind, event) when is_atom(kind) and is_map(event) do
    GenServer.cast(server, {:github_update, kind, event})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init({sprite_id, opts}) do
    state_opts = [
      name: Keyword.get(opts, :sprite_name),
      status: Keyword.get(opts, :status, :cold),
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
  def handle_cast({:github_update, kind, event}, {state, interval}) do
    Logger.info("Sprite #{state.sprite_id} received GitHub update",
      event_kind: kind,
      number: Map.get(event, :number)
    )

    log_line = Logs.from_event(:github_update, state.sprite_id, %{kind: kind, event: event})
    Events.broadcast_sprite_log(state.sprite_id, log_line)

    {:noreply, {state, interval}}
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

  # ── Observation Logic ────────────────────────────────────────────

  defp do_reconcile(%State{} = state) do
    start_time = System.monotonic_time(:millisecond)

    case fetch_sprite_data(state) do
      {:ok, api_status, api_data} ->
        handle_observation(state, api_status, api_data, start_time)

      {:error, :not_found} ->
        handle_not_found(state, start_time)

      {:error, reason} ->
        handle_fetch_failure(state, reason, start_time)
    end
  end

  # Fetch the full sprite data from the SpritesCapability API.
  # Returns {status_atom, raw_api_map} so callers can extract timestamps.
  defp fetch_sprite_data(%State{sprite_id: sprite_id}) do
    case sprites_capability().get_sprite(sprite_id) do
      {:ok, %{status: status} = data} when is_atom(status) ->
        {:ok, status, stringify_keys(data)}

      {:ok, %{status: status} = data} when is_binary(status) ->
        {:ok, parse_api_status(status), stringify_keys(data)}

      {:ok, data} ->
        {:ok, :cold, stringify_keys(data)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp parse_api_status("running"), do: :running
  defp parse_api_status("cold"), do: :cold
  defp parse_api_status("warm"), do: :warm
  defp parse_api_status("sleeping"), do: :cold
  defp parse_api_status(_other), do: :cold

  defp handle_observation(%State{} = state, api_status, api_data, start_time) do
    old_status = state.status
    duration = System.monotonic_time(:millisecond) - start_time

    case State.update_status(state, api_status) do
      {:ok, new_state} ->
        new_state = State.record_observation(new_state)
        new_state = State.update_api_timestamps(new_state, api_data)
        new_state = State.reset_backoff(new_state)
        new_state = %{new_state | not_found_count: 0}

        if old_status != api_status do
          emit_state_change(state.sprite_id, old_status, api_status, "API observation")
        end

        emit_reconciliation_result(new_state, :no_change, duration)

        {new_state, :no_change}

      {:error, _} ->
        {state, :failure}
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
        %{sprite_id: state.sprite_id, last_state: state.status}
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
    new_state = State.record_failure(state)
    new_state = %{new_state | not_found_count: 0}

    Logger.warning("Sprite observation failure",
      sprite_id: state.sprite_id,
      reason: inspect(reason)
    )

    emit_reconciliation_result(
      new_state,
      :failure,
      duration,
      "API fetch failed: #{inspect(reason)}"
    )

    {new_state, :failure}
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
