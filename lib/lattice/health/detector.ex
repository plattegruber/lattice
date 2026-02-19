defmodule Lattice.Health.Detector do
  @moduledoc """
  Subscribes to observation events and creates health_detect intents
  based on severity-gating rules.

  ## Severity Gating

  | Severity   | Action                                          |
  |------------|-------------------------------------------------|
  | `:critical` | Auto-create intent, create GitHub issue          |
  | `:high`     | Create intent requiring operator approval        |
  | `:medium`   | Log observation, no intent                       |
  | `:low`      | Log observation, no intent                       |
  | `:info`     | Metric tracking only                             |

  ## Deduplication

  Tracks recent detections per sprite+type to avoid duplicate intents
  within a configurable cooldown window (default: 5 minutes).

  ## Configuration

      config :lattice, Lattice.Health.Detector,
        enabled: true,
        cooldown_ms: 300_000,
        create_issues: true
  """

  use GenServer

  require Logger

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Observation
  alias Lattice.Intents.Store

  @default_cooldown_ms :timer.minutes(5)

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current detection history (for testing/debugging)."
  @spec detection_history() :: map()
  def detection_history do
    GenServer.call(__MODULE__, :detection_history)
  end

  @doc "Clears the detection history (for testing)."
  @spec clear_history() :: :ok
  def clear_history do
    GenServer.call(__MODULE__, :clear_history)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    Events.subscribe_all_observations()

    {:ok,
     %{
       history: %{},
       cooldown_ms: config(:cooldown_ms, @default_cooldown_ms)
     }}
  end

  @impl true
  def handle_call(:detection_history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:clear_history, _from, state) do
    {:reply, :ok, %{state | history: %{}}}
  end

  @impl true
  def handle_info(%Observation{} = obs, state) do
    state = process_observation(obs, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Processing ──────────────────────────────────────────────────

  defp process_observation(%Observation{severity: severity} = obs, state)
       when severity in [:critical, :high] do
    dedup_key = {obs.sprite_id, obs.type, to_string(obs.data["category"] || obs.type)}

    if recently_detected?(state, dedup_key) do
      Logger.debug("Health detection skipped (cooldown): #{inspect(dedup_key)}")
      state
    else
      create_detection_intent(obs)
      record_detection(state, dedup_key)
    end
  end

  defp process_observation(%Observation{severity: :medium} = obs, state) do
    Logger.info(
      "Health observation (medium): #{obs.sprite_id} #{obs.type} - #{inspect(obs.data)}"
    )

    state
  end

  defp process_observation(%Observation{severity: :low} = obs, state) do
    Logger.debug("Health observation (low): #{obs.sprite_id} #{obs.type}")
    state
  end

  defp process_observation(%Observation{}, state), do: state

  # ── Intent Creation ─────────────────────────────────────────────

  defp create_detection_intent(%Observation{} = obs) do
    source = %{type: :system, id: "health_detector"}

    summary =
      case obs.data do
        %{"message" => msg} when is_binary(msg) -> msg
        %{"description" => desc} when is_binary(desc) -> desc
        _ -> "Health issue detected: #{obs.type} on #{obs.sprite_id}"
      end

    payload = %{
      "observation_type" => to_string(obs.type),
      "severity" => to_string(obs.severity),
      "sprite_id" => obs.sprite_id,
      "observation_id" => obs.id,
      "observation_data" => obs.data
    }

    auto_approve? = obs.severity == :critical

    case Intent.new(:health_detect, source,
           summary: summary,
           payload: payload
         ) do
      {:ok, intent} ->
        case Store.create(intent) do
          {:ok, stored} ->
            if auto_approve? do
              # Walk through the state machine: proposed → classified → approved
              Store.update(stored.id, %{state: :classified})
              Store.update(stored.id, %{state: :approved, actor: "health_detector"})
            end

            Logger.info(
              "Health detection intent created: #{intent.id} " <>
                "(severity=#{obs.severity}, auto_approve=#{auto_approve?})"
            )

          {:error, reason} ->
            Logger.warning("Failed to store health detection intent: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to create health detection intent: #{inspect(reason)}")
    end
  end

  # ── Deduplication ───────────────────────────────────────────────

  defp recently_detected?(state, key) do
    case Map.get(state.history, key) do
      nil -> false
      last_at -> DateTime.diff(DateTime.utc_now(), last_at, :millisecond) < state.cooldown_ms
    end
  end

  defp record_detection(state, key) do
    %{state | history: Map.put(state.history, key, DateTime.utc_now())}
  end

  # ── Config ──────────────────────────────────────────────────────

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
