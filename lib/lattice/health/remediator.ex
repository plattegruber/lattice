defmodule Lattice.Health.Remediator do
  @moduledoc """
  Watches for approved health_detect intents and proposes health_remediate
  intents linked back to the originating detection.

  When a health issue is detected and classified, the Remediator creates a
  remediation intent that flows through the standard Pipeline (classify → gate).
  For critical severities with auto-remediation enabled, the remediation intent
  is auto-approved. Otherwise it awaits operator approval.

  ## Configuration

      config :lattice, Lattice.Health.Remediator,
        enabled: true,
        auto_remediate_severities: [:critical]
  """

  use GenServer

  require Logger

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current remediation history."
  @spec history() :: [map()]
  def history do
    GenServer.call(__MODULE__, :history)
  end

  @doc "Clears the remediation history (for testing)."
  @spec clear_history() :: :ok
  def clear_history do
    GenServer.call(__MODULE__, :clear_history)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Subscribe to store-level intent mutations (not pipeline-level).
    # The Detector bypasses Pipeline and calls Store.update directly,
    # which emits {:intent_transitioned, intent} on the "intents" topic.
    Events.subscribe_intents()

    {:ok,
     %{
       history: [],
       auto_severities: config(:auto_remediate_severities, [:critical])
     }}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:clear_history, _from, state) do
    {:reply, :ok, %{state | history: []}}
  end

  @impl true
  def handle_info(
        {:intent_transitioned, %Intent{kind: :health_detect, state: :approved} = intent},
        state
      ) do
    state = maybe_propose_remediation(intent, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Remediation Proposal ────────────────────────────────────────

  defp maybe_propose_remediation(%Intent{} = detect_intent, state) do
    severity = detect_intent.payload["severity"] || "high"
    severity_atom = parse_severity(severity)

    source = %{type: :system, id: "health_remediator"}

    payload = %{
      "detect_intent_id" => detect_intent.id,
      "remediation_type" => "auto_fix",
      "severity" => to_string(severity_atom),
      "original_summary" => detect_intent.summary,
      "observation_data" => detect_intent.payload["observation_data"]
    }

    summary = "Remediate: #{detect_intent.summary}"

    case Intent.new(:health_remediate, source, summary: summary, payload: payload) do
      {:ok, intent} ->
        case Pipeline.propose(intent) do
          {:ok, proposed} ->
            proposed = maybe_auto_approve(proposed, severity_atom, state)

            entry = %{
              detect_intent_id: detect_intent.id,
              remediate_intent_id: proposed.id,
              severity: severity_atom,
              auto_approved: proposed.state == :approved,
              created_at: DateTime.utc_now()
            }

            Logger.info(
              "Health remediation proposed: #{proposed.id} " <>
                "(detect=#{detect_intent.id}, severity=#{severity_atom}, " <>
                "state=#{proposed.state})"
            )

            %{state | history: [entry | state.history]}

          {:error, reason} ->
            Logger.warning("Failed to propose health remediation: #{inspect(reason)}")

            state
        end

      {:error, reason} ->
        Logger.warning("Failed to create health remediation intent: #{inspect(reason)}")

        state
    end
  end

  defp maybe_auto_approve(%Intent{state: :awaiting_approval} = intent, severity, state) do
    if severity in state.auto_severities do
      case Pipeline.approve(intent.id, actor: "health_remediator", reason: "auto-remediation") do
        {:ok, approved} -> approved
        {:error, _} -> intent
      end
    else
      intent
    end
  end

  defp maybe_auto_approve(intent, _severity, _state), do: intent

  defp parse_severity(severity) when is_atom(severity), do: severity

  defp parse_severity(severity) when is_binary(severity) do
    String.to_existing_atom(severity)
  rescue
    ArgumentError -> :high
  end

  # ── Config ──────────────────────────────────────────────────────

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
