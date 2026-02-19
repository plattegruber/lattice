defmodule Lattice.Docs.DriftDetector do
  @moduledoc """
  Detects documentation drift by monitoring completed intents and checking
  whether associated documentation needs updating.

  ## How it works

  When an intent completes that modified code (e.g., API endpoints, config),
  the detector checks whether the associated repo profile has doc_paths
  configured and whether the changes qualify for a doc update requirement.

  ## Change types that require doc updates

  - New API endpoint added → API docs need updating
  - New intent kind registered → concepts docs need updating
  - Configuration changes → deployment/config docs need updating
  - Safety classification changes → safety docs need updating

  ## Configuration

      config :lattice, Lattice.Docs.DriftDetector,
        enabled: true,
        change_types: [:api_endpoint, :intent_kind, :config, :safety]
  """

  use GenServer

  require Logger

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Policy.RepoProfile

  @default_change_types [:api_endpoint, :intent_kind, :config, :safety]

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns detected drift entries."
  @spec drift_log() :: [map()]
  def drift_log do
    GenServer.call(__MODULE__, :drift_log)
  end

  @doc "Checks a completed intent for documentation drift. Returns drift info or nil."
  @spec check_intent(Intent.t()) :: map() | nil
  def check_intent(%Intent{} = intent) do
    GenServer.call(__MODULE__, {:check_intent, intent})
  end

  @doc "Clears the drift log (for testing)."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    if enabled?() do
      Events.subscribe_intents()
    end

    {:ok,
     %{
       drift_log: [],
       change_types: config(:change_types, @default_change_types)
     }}
  end

  @impl true
  def handle_call(:drift_log, _from, state) do
    {:reply, state.drift_log, state}
  end

  def handle_call({:check_intent, intent}, _from, state) do
    case detect_drift(intent, state.change_types) do
      nil -> {:reply, nil, state}
      drift -> {:reply, drift, state}
    end
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | drift_log: []}}
  end

  @impl true
  def handle_info({:intent_transitioned, %Intent{state: :completed} = intent}, state) do
    case detect_drift(intent, state.change_types) do
      nil ->
        {:noreply, state}

      drift ->
        Logger.info("Documentation drift detected: #{drift.reason} for #{intent.id}")

        :telemetry.execute(
          [:lattice, :docs, :drift_detected],
          %{count: 1},
          %{reason: drift.reason, repo: drift.repo}
        )

        Phoenix.PubSub.broadcast(Lattice.PubSub, "docs:drift", {:doc_drift_detected, drift})
        {:noreply, %{state | drift_log: [drift | Enum.take(state.drift_log, 99)]}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Detection Logic ─────────────────────────────────────────────

  defp detect_drift(%Intent{} = intent, change_types) do
    repo = get_repo(intent)

    cond do
      repo == nil ->
        nil

      :api_endpoint in change_types && api_change?(intent) ->
        build_drift(intent, repo, :api_endpoint, "API endpoint change may require docs update", [
          "API documentation"
        ])

      :config in change_types && config_change?(intent) ->
        build_drift(intent, repo, :config, "Configuration change may require docs update", [
          "Deployment/config documentation"
        ])

      :safety in change_types && safety_change?(intent) ->
        build_drift(
          intent,
          repo,
          :safety,
          "Safety classification change may require docs update",
          [
            "Safety documentation"
          ]
        )

      true ->
        nil
    end
  end

  defp build_drift(intent, repo, change_type, reason, affected_docs) do
    profile = RepoProfile.get_or_default(repo)

    doc_paths =
      case profile.doc_paths do
        [] -> affected_docs
        paths -> paths
      end

    %{
      intent_id: intent.id,
      repo: repo,
      change_type: change_type,
      reason: reason,
      affected_docs: doc_paths,
      detected_at: DateTime.utc_now()
    }
  end

  defp api_change?(%Intent{payload: payload}) when is_map(payload) do
    capability = payload["capability"] || to_string(Map.get(payload, :capability, ""))

    capability in ["sprites", "fleet", "intents"] &&
      operation_is_mutation?(payload)
  end

  defp api_change?(_), do: false

  defp config_change?(%Intent{kind: kind}) do
    kind in [:maintenance]
  end

  defp safety_change?(%Intent{payload: payload}) when is_map(payload) do
    capability = payload["capability"] || to_string(Map.get(payload, :capability, ""))
    capability == "safety"
  end

  defp safety_change?(_), do: false

  defp operation_is_mutation?(payload) do
    operation = payload["operation"] || to_string(Map.get(payload, :operation, ""))

    String.starts_with?(operation, "create") ||
      String.starts_with?(operation, "delete") ||
      String.starts_with?(operation, "update") ||
      String.starts_with?(operation, "add")
  end

  defp get_repo(%Intent{payload: payload}) when is_map(payload) do
    payload["repo"] || Map.get(payload, :repo)
  end

  defp get_repo(_), do: nil

  defp enabled? do
    config(:enabled, true)
  end

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
