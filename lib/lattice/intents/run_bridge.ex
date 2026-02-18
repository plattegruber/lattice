defmodule Lattice.Intents.RunBridge do
  @moduledoc """
  Bridges Run lifecycle events to Intent state transitions.

  Subscribes to the `"runs"` PubSub topic and, when a run enters a blocked
  state or resumes, propagates that state change to the parent intent.
  This keeps Run and Intent decoupled — the bridge is an observer process.

  ## Event Mapping

  - `{:run_blocked, %Run{status: :blocked}}` → Intent transitions to `:blocked`
  - `{:run_blocked, %Run{status: :blocked_waiting_for_user}}` → Intent transitions to `:waiting_for_input`
  - `{:run_resumed, %Run{}}` → Intent transitions back to `:running`
  """

  use GenServer
  require Logger

  alias Lattice.Events
  alias Lattice.Intents.Store

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    Events.subscribe_runs()
    {:ok, %{}}
  end

  # ── Run Blocked Events ──────────────────────────────────────────────

  @impl GenServer
  def handle_info({:run_blocked, %{intent_id: nil}}, state), do: {:noreply, state}

  def handle_info({:run_blocked, %{intent_id: intent_id, status: :blocked} = run}, state) do
    transition_intent_to_blocked(intent_id, run.blocked_reason)
    {:noreply, state}
  end

  def handle_info(
        {:run_blocked, %{intent_id: intent_id, status: :blocked_waiting_for_user} = run},
        state
      ) do
    transition_intent_to_waiting(intent_id, run.question)
    {:noreply, state}
  end

  # ── Run Resumed Events ─────────────────────────────────────────────

  def handle_info({:run_resumed, %{intent_id: nil}}, state), do: {:noreply, state}

  def handle_info({:run_resumed, %{intent_id: intent_id}}, state) do
    transition_intent_to_running(intent_id)
    {:noreply, state}
  end

  # Ignore all other messages
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────

  defp transition_intent_to_blocked(intent_id, reason) do
    with {:ok, intent} <- Store.get(intent_id),
         true <- intent.state == :running do
      case Store.update(intent_id, %{
             state: :blocked,
             blocked_reason: reason,
             actor: :run_bridge,
             reason: "run blocked: #{reason || "unknown"}"
           }) do
        {:ok, updated} ->
          Events.emit_intent_blocked(updated)

        {:error, err} ->
          Logger.warning("RunBridge: failed to block intent #{intent_id}: #{inspect(err)}")
      end
    else
      {:error, :not_found} ->
        Logger.debug("RunBridge: intent #{intent_id} not found, ignoring block event")

      false ->
        Logger.debug("RunBridge: intent #{intent_id} not in :running state, ignoring block event")
    end
  end

  defp transition_intent_to_waiting(intent_id, question) do
    with {:ok, intent} <- Store.get(intent_id),
         true <- intent.state == :running do
      case Store.update(intent_id, %{
             state: :waiting_for_input,
             pending_question: question,
             actor: :run_bridge,
             reason: "run waiting for user input"
           }) do
        {:ok, updated} ->
          Events.emit_intent_blocked(updated)

        {:error, err} ->
          Logger.warning(
            "RunBridge: failed to set intent #{intent_id} to waiting_for_input: #{inspect(err)}"
          )
      end
    else
      {:error, :not_found} ->
        Logger.debug("RunBridge: intent #{intent_id} not found, ignoring block_for_input event")

      false ->
        Logger.debug(
          "RunBridge: intent #{intent_id} not in :running state, ignoring block_for_input event"
        )
    end
  end

  defp transition_intent_to_running(intent_id) do
    with {:ok, intent} <- Store.get(intent_id),
         true <- intent.state in [:blocked, :waiting_for_input] do
      case Store.update(intent_id, %{
             state: :running,
             blocked_reason: nil,
             pending_question: nil,
             actor: :run_bridge,
             reason: "run resumed"
           }) do
        {:ok, updated} ->
          Events.emit_intent_resumed(updated)

        {:error, err} ->
          Logger.warning("RunBridge: failed to resume intent #{intent_id}: #{inspect(err)}")
      end
    else
      {:error, :not_found} ->
        Logger.debug("RunBridge: intent #{intent_id} not found, ignoring resume event")

      false ->
        Logger.debug(
          "RunBridge: intent #{intent_id} not in blocked/waiting state, ignoring resume event"
        )
    end
  end
end
