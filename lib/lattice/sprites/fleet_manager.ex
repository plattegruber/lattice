defmodule Lattice.Sprites.FleetManager do
  @moduledoc """
  Fleet Manager: sprite discovery and lifecycle coordination.

  The Fleet Manager is a GenServer responsible for:

  - **Discovery** -- reading the configured sprite list and starting a
    `Lattice.Sprites.Sprite` GenServer for each one under a DynamicSupervisor
  - **Fleet queries** -- `list_sprites/0`, `fleet_summary/0`, `get_sprite_pid/1`
  - **Fleet-wide operations** -- `wake_sprites/1`, `sleep_sprites/1`, `run_audit/0`
  - **Observability** -- broadcasting fleet summary updates via PubSub on the
    `"sprites:fleet"` topic after every fleet-mutating operation

  ## Supervision

  The Fleet Manager sits in the application supervision tree alongside:

  - `Lattice.Sprites.Registry` -- process lookup by sprite_id
  - `Lattice.Sprites.DynamicSupervisor` -- supervises individual Sprite GenServers

  ## Configuration

  Sprite discovery reads from the Sprites API or application config.

  ## Events

  After fleet-mutating operations, the Fleet Manager broadcasts a
  `{:fleet_summary, summary}` message on the `"sprites:fleet"` PubSub topic
  and emits a `[:lattice, :fleet, :summary]` Telemetry event.
  """

  use GenServer

  require Logger

  alias Lattice.Events
  alias Lattice.Sprites.SkillSync
  alias Lattice.Sprites.Sprite
  alias Lattice.Sprites.State

  @default_fast_interval_ms 10_000
  @default_slow_interval_ms 60_000

  defmodule FleetState do
    @moduledoc false
    @type t :: %__MODULE__{
            sprite_ids: [String.t()],
            supervisor: atom() | pid(),
            fleet_reconcile_ref: reference() | nil,
            started_at: DateTime.t()
          }

    @enforce_keys [:supervisor, :started_at]
    defstruct [:supervisor, :started_at, :fleet_reconcile_ref, sprite_ids: []]
  end

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start the Fleet Manager.

  ## Options

  - `:name` -- GenServer name (default: `__MODULE__`)
  - `:supervisor` -- DynamicSupervisor name (default: `Lattice.Sprites.DynamicSupervisor`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  List all managed sprite IDs with their current state.

  Returns a list of `{sprite_id, %Lattice.Sprites.State{}}` tuples for all
  sprites that are alive and responding.
  """
  @spec list_sprites(GenServer.server()) :: [{String.t(), State.t()}]
  def list_sprites(server \\ __MODULE__) do
    GenServer.call(server, :list_sprites)
  end

  @doc """
  Get the PID of a sprite process by its ID.

  Returns `{:ok, pid}` if the sprite is found in the Registry, or
  `{:error, :not_found}` otherwise.
  """
  @spec get_sprite_pid(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_sprite_pid(sprite_id) when is_binary(sprite_id) do
    case Registry.lookup(Lattice.Sprites.Registry, sprite_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Return a summary of the fleet: total count and breakdown by status.

  ## Example

      FleetManager.fleet_summary()
      #=> %{total: 3, by_state: %{cold: 2, running: 1}}
  """
  @spec fleet_summary(GenServer.server()) :: map()
  def fleet_summary(server \\ __MODULE__) do
    GenServer.call(server, :fleet_summary)
  end

  @doc """
  Wake the given sprites by calling the Sprites API directly.

  Returns a map of `%{sprite_id => :ok | {:error, reason}}`.
  """
  @spec wake_sprites([String.t()], GenServer.server()) :: %{String.t() => :ok | {:error, term()}}
  def wake_sprites(sprite_ids, server \\ __MODULE__) when is_list(sprite_ids) do
    GenServer.call(server, {:wake_sprites, sprite_ids})
  end

  @doc """
  Sleep the given sprites by calling the Sprites API directly.

  Returns a map of `%{sprite_id => :ok | {:error, reason}}`.
  """
  @spec sleep_sprites([String.t()], GenServer.server()) :: %{
          String.t() => :ok | {:error, term()}
        }
  def sleep_sprites(sprite_ids, server \\ __MODULE__) when is_list(sprite_ids) do
    GenServer.call(server, {:sleep_sprites, sprite_ids})
  end

  @doc """
  Add a sprite to the fleet at runtime.

  Starts a new Sprite GenServer under the DynamicSupervisor and registers
  it in the fleet. Broadcasts a fleet summary update via PubSub so the
  LiveView dashboard picks up the new sprite.

  Returns `{:ok, sprite_id}` on success, or `{:error, :already_exists}`
  if a sprite with that ID is already in the fleet.
  """
  @spec add_sprite(String.t(), keyword(), GenServer.server()) ::
          {:ok, String.t()} | {:error, :already_exists}
  def add_sprite(sprite_id, opts \\ [], server \\ __MODULE__) when is_binary(sprite_id) do
    GenServer.call(server, {:add_sprite, sprite_id, opts})
  end

  @doc """
  Remove a sprite from the fleet.

  Terminates the sprite's GenServer and removes it from the fleet's tracked
  sprite IDs. Broadcasts a fleet summary update via PubSub so the LiveView
  dashboard reflects the change.

  Returns `:ok` on success, or `{:error, :not_found}` if the sprite is not
  tracked by the fleet.
  """
  @spec remove_sprite(String.t(), GenServer.server()) :: :ok | {:error, :not_found}
  def remove_sprite(sprite_id, server \\ __MODULE__) when is_binary(sprite_id) do
    GenServer.call(server, {:remove_sprite, sprite_id})
  end

  @doc """
  Trigger an immediate observation cycle on all managed sprites.

  Returns `:ok` after sending reconcile commands to all sprites.
  """
  @spec run_audit(GenServer.server()) :: :ok
  def run_audit(server \\ __MODULE__) do
    GenServer.call(server, :run_audit)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    supervisor = Keyword.get(opts, :supervisor, Lattice.Sprites.DynamicSupervisor)

    Phoenix.PubSub.subscribe(Lattice.PubSub, Events.fleet_topic())

    state = %FleetState{
      supervisor: supervisor,
      started_at: DateTime.utc_now()
    }

    {:ok, state, {:continue, :discover_sprites}}
  end

  @impl true
  def handle_continue(:discover_sprites, %FleetState{} = state) do
    sprite_configs = discover_sprites()

    sprite_ids =
      sprite_configs
      |> Enum.map(&start_sprite(&1, state.supervisor))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, sprite_id} -> sprite_id end)

    new_state = %{state | sprite_ids: sprite_ids}

    Logger.info("Fleet Manager started #{length(sprite_ids)} sprites",
      total: length(sprite_ids),
      sprite_ids: inspect(sprite_ids)
    )

    broadcast_fleet_summary(new_state)

    # Sync sprite skills on startup (non-blocking)
    Task.start(fn -> SkillSync.sync_all() end)

    new_state = schedule_fleet_reconcile(new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:list_sprites, _from, %FleetState{} = state) do
    sprites =
      state.sprite_ids
      |> Enum.map(fn id -> {id, get_sprite_state(id)} end)
      |> Enum.filter(fn {_id, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {id, {:ok, sprite_state}} -> {id, sprite_state} end)

    {:reply, sprites, state}
  end

  def handle_call(:fleet_summary, _from, %FleetState{} = state) do
    summary = compute_fleet_summary(state)
    {:reply, summary, state}
  end

  def handle_call({:wake_sprites, sprite_ids}, _from, %FleetState{} = state) do
    results = call_capability_for_sprites(sprite_ids, :wake)
    broadcast_fleet_summary(state)
    {:reply, results, state}
  end

  def handle_call({:sleep_sprites, sprite_ids}, _from, %FleetState{} = state) do
    results = call_capability_for_sprites(sprite_ids, :sleep)
    broadcast_fleet_summary(state)
    {:reply, results, state}
  end

  def handle_call({:add_sprite, sprite_id, opts}, _from, %FleetState{} = state) do
    if sprite_id in state.sprite_ids do
      {:reply, {:error, :already_exists}, state}
    else
      sprite_name = Keyword.get(opts, :sprite_name)
      config = %{id: sprite_id, name: sprite_name}

      case start_sprite(config, state.supervisor) do
        {:ok, ^sprite_id} ->
          new_state = %{state | sprite_ids: state.sprite_ids ++ [sprite_id]}
          broadcast_fleet_summary(new_state)
          {:reply, {:ok, sprite_id}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:remove_sprite, sprite_id}, _from, %FleetState{} = state) do
    if sprite_id in state.sprite_ids do
      case get_sprite_pid(sprite_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(state.supervisor, pid)

        {:error, :not_found} ->
          :ok
      end

      Lattice.Store.delete(:sprite_metadata, sprite_id)

      new_state = %{state | sprite_ids: List.delete(state.sprite_ids, sprite_id)}
      broadcast_fleet_summary(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:run_audit, _from, %FleetState{} = state) do
    Enum.each(state.sprite_ids, fn id ->
      case get_sprite_pid(id) do
        {:ok, pid} -> Sprite.reconcile_now(pid)
        {:error, :not_found} -> :ok
      end
    end)

    broadcast_fleet_summary(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:fleet_reconcile, %FleetState{} = state) do
    new_state = do_fleet_reconcile(state)
    new_state = schedule_fleet_reconcile(new_state)
    {:noreply, new_state}
  end

  def handle_info({:sprite_externally_deleted, sprite_id}, %FleetState{} = state) do
    if sprite_id in state.sprite_ids do
      Logger.info("Removing externally-deleted sprite #{sprite_id} from fleet")
      Lattice.Store.delete(:sprite_metadata, sprite_id)
      new_state = %{state | sprite_ids: List.delete(state.sprite_ids, sprite_id)}
      broadcast_fleet_summary(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Ignore other PubSub messages on the fleet topic (state changes,
  # reconciliation results, etc.) — only externally-deleted
  # messages need fleet-manager-level handling.
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp discover_sprites do
    capability = sprites_capability()

    if capability && function_exported?(capability, :list_sprites, 0) do
      case capability.list_sprites() do
        {:ok, api_sprites} ->
          Logger.info("Discovered #{length(api_sprites)} sprites from API")
          Enum.map(api_sprites, &api_sprite_to_config/1)

        {:error, reason} ->
          Logger.warning(
            "API sprite discovery failed: #{inspect(reason)}, falling back to config"
          )

          configured_sprites()
      end
    else
      configured_sprites()
    end
  end

  defp api_sprite_to_config(sprite) do
    sprite_id = sprite[:id] || sprite["id"]

    base = %{
      id: sprite_id,
      name: sprite[:name] || sprite["name"]
    }

    # Restore persisted metadata (tags) from the store
    case Lattice.Store.get(:sprite_metadata, sprite_id) do
      {:ok, metadata} ->
        maybe_restore_tags(base, metadata)

      {:error, :not_found} ->
        base
    end
  end

  defp maybe_restore_tags(config, metadata) do
    case Map.get(metadata, :tags) do
      tags when is_map(tags) and tags != %{} -> Map.put(config, :tags, tags)
      _ -> config
    end
  end

  defp sprites_capability do
    Application.get_env(:lattice, :capabilities)[:sprites]
  end

  defp configured_sprites do
    :lattice
    |> Application.get_env(:fleet, [])
    |> Keyword.get(:sprites, [])
  end

  defp start_sprite(%{id: sprite_id} = config, supervisor) do
    sprite_name = Map.get(config, :name)
    tags = Map.get(config, :tags, %{})

    child_spec =
      {Sprite,
       [
         sprite_id: sprite_id,
         sprite_name: sprite_name,
         tags: tags,
         name: Sprite.via(sprite_id)
       ]}

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, _pid} ->
        Logger.info("Started sprite #{sprite_id}")
        {:ok, sprite_id}

      {:error, {:already_started, _pid}} ->
        Logger.info("Sprite #{sprite_id} already running")
        {:ok, sprite_id}

      {:error, reason} ->
        Logger.error("Failed to start sprite #{sprite_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_sprite_state(sprite_id) do
    case get_sprite_pid(sprite_id) do
      {:ok, pid} -> Sprite.get_state(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp call_capability_for_sprites(sprite_ids, action) do
    capability = sprites_capability()

    Map.new(sprite_ids, fn id ->
      result =
        case apply(capability, action, [id]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {id, result}
    end)
  end

  defp compute_fleet_summary(%FleetState{} = state) do
    sprites =
      state.sprite_ids
      |> Enum.map(fn id -> {id, get_sprite_state(id)} end)
      |> Enum.filter(fn {_id, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {_id, {:ok, sprite_state}} -> sprite_state end)

    by_state =
      sprites
      |> Enum.group_by(& &1.status)
      |> Map.new(fn {state_name, group} -> {state_name, length(group)} end)

    %{
      total: length(sprites),
      by_state: by_state
    }
  end

  defp broadcast_fleet_summary(%FleetState{} = state) do
    summary = compute_fleet_summary(state)
    Events.emit_fleet_summary(summary)

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      Events.fleet_topic(),
      {:fleet_summary, summary}
    )
  end

  # ── Fleet Reconciliation Loop ────────────────────────────────────

  defp schedule_fleet_reconcile(%FleetState{} = state) do
    interval = fleet_reconcile_interval()
    ref = Process.send_after(self(), :fleet_reconcile, interval)
    %{state | fleet_reconcile_ref: ref}
  end

  defp fleet_reconcile_interval do
    if presence_has_viewers?() do
      Application.get_env(:lattice, :fleet_reconcile_fast_ms, @default_fast_interval_ms)
    else
      Application.get_env(:lattice, :fleet_reconcile_slow_ms, @default_slow_interval_ms)
    end
  end

  defp presence_has_viewers? do
    # Guard against Presence not being started (e.g. in test env)
    if Process.whereis(LatticeWeb.Presence) do
      LatticeWeb.Presence.has_viewers?()
    else
      false
    end
  end

  defp do_fleet_reconcile(%FleetState{} = state) do
    capability = sprites_capability()

    if capability && function_exported?(capability, :list_sprites, 0) do
      case capability.list_sprites() do
        {:ok, api_sprites} ->
          apply_fleet_reconcile(state, api_sprites)

        {:error, _reason} ->
          broadcast_fleet_summary(state)
          state
      end
    else
      broadcast_fleet_summary(state)
      state
    end
  end

  defp apply_fleet_reconcile(%FleetState{} = state, api_sprites) do
    start_time = System.monotonic_time(:millisecond)
    api_ids = MapSet.new(api_sprites, fn s -> s[:id] || s["id"] end)
    known_ids = MapSet.new(state.sprite_ids)

    new_ids = MapSet.difference(api_ids, known_ids)
    removed_ids = MapSet.difference(known_ids, api_ids)

    added = start_new_sprites(api_sprites, new_ids, state.supervisor)
    remove_stale_sprites(removed_ids, state.supervisor)

    updated_ids = (state.sprite_ids -- MapSet.to_list(removed_ids)) ++ added
    duration = System.monotonic_time(:millisecond) - start_time
    emit_fleet_reconcile_telemetry(length(added), MapSet.size(removed_ids), duration)

    if added != [] or MapSet.size(removed_ids) > 0 do
      new_state = %{state | sprite_ids: updated_ids}
      broadcast_fleet_summary(new_state)
      new_state
    else
      broadcast_fleet_summary(state)
      state
    end
  end

  defp start_new_sprites(api_sprites, new_ids, supervisor) do
    api_sprites
    |> Enum.filter(fn s -> (s[:id] || s["id"]) in new_ids end)
    |> Enum.map(&api_sprite_to_config/1)
    |> Enum.map(&start_sprite(&1, supervisor))
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, id} -> id end)
  end

  defp remove_stale_sprites(removed_ids, supervisor) do
    Enum.each(removed_ids, fn id ->
      case get_sprite_pid(id) do
        {:ok, pid} -> DynamicSupervisor.terminate_child(supervisor, pid)
        _ -> :ok
      end

      Lattice.Store.delete(:sprite_metadata, id)
    end)
  end

  defp emit_fleet_reconcile_telemetry(added, removed, duration_ms) do
    :telemetry.execute(
      [:lattice, :fleet, :reconcile],
      %{duration_ms: duration_ms, added: added, removed: removed},
      %{}
    )
  end
end
