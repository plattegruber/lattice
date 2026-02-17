defmodule Lattice.Intents.Governance.Listener do
  @moduledoc """
  GenServer that listens for intent pipeline events and triggers governance actions.

  Subscribes to the `"intents:all"` PubSub topic on start. When an intent
  transitions to `:awaiting_approval`, it creates a GitHub governance issue.
  When an intent execution completes or fails, it posts the outcome to the
  governance issue. When an intent reaches a terminal state, it closes the
  governance issue.

  Also runs a periodic sync that checks all awaiting-approval intents against
  their governance issues to pick up label changes made by humans on GitHub.

  ## Configuration

  The sync interval defaults to 30 seconds and can be overridden via the
  `:sync_interval_ms` option at start.
  """

  use GenServer

  require Logger

  alias Lattice.Intents.Governance
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store

  @default_sync_interval_ms 30_000

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────

  @impl true
  def init(opts) do
    sync_interval = Keyword.get(opts, :sync_interval_ms, @default_sync_interval_ms)

    Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:all")

    schedule_sync(sync_interval)

    {:ok, %{sync_interval_ms: sync_interval}}
  end

  @impl true
  def handle_info({:intent_awaiting_approval, %Intent{} = intent}, state) do
    handle_awaiting_approval(intent)
    {:noreply, state}
  end

  def handle_info({:intent_execution_completed, %Intent{} = intent, result}, state) do
    handle_execution_outcome(intent, result_to_map(result))
    {:noreply, state}
  end

  def handle_info({:intent_execution_failed, %Intent{} = intent, error}, state) do
    handle_execution_outcome(intent, %{status: :failure, error: error})
    {:noreply, state}
  end

  def handle_info({:intent_rejected, %Intent{} = intent}, state) do
    handle_terminal(intent)
    {:noreply, state}
  end

  def handle_info({:intent_canceled, %Intent{} = intent}, state) do
    handle_terminal(intent)
    {:noreply, state}
  end

  def handle_info(:sync_governance, state) do
    sync_all_awaiting_intents()
    schedule_sync(state.sync_interval_ms)
    {:noreply, state}
  end

  # Catch-all for other PubSub events
  def handle_info(_event, state) do
    {:noreply, state}
  end

  # ── Private: Event Handlers ──────────────────────────────────────

  defp handle_awaiting_approval(%Intent{} = intent) do
    case Governance.create_governance_issue(intent) do
      {:ok, _updated} ->
        Logger.info("Created governance issue for intent #{intent.id}")

      {:error, reason} ->
        Logger.error(
          "Failed to create governance issue for intent #{intent.id}: #{inspect(reason)}"
        )
    end
  end

  defp handle_execution_outcome(%Intent{} = intent, result) do
    case Governance.post_outcome(intent, result) do
      {:ok, _comment} ->
        Logger.debug("Posted outcome for intent #{intent.id}")

      {:error, :no_governance_issue} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to post outcome for intent #{intent.id}: #{inspect(reason)}")
    end

    handle_terminal(intent)
  end

  defp handle_terminal(%Intent{state: state} = intent)
       when state in [:completed, :failed, :rejected, :canceled] do
    case Governance.close_governance_issue(intent) do
      {:ok, _issue} ->
        Logger.debug("Closed governance issue for intent #{intent.id}")

      {:error, :no_governance_issue} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to close governance issue for intent #{intent.id}: #{inspect(reason)}"
        )
    end
  end

  defp handle_terminal(_intent), do: :ok

  # ── Private: Periodic Sync ───────────────────────────────────────

  defp sync_all_awaiting_intents do
    {:ok, intents} = Store.list(%{state: :awaiting_approval})

    Enum.each(intents, fn intent ->
      case Governance.sync_from_github(intent) do
        {:ok, :no_change} ->
          :ok

        {:ok, %Intent{}} ->
          Logger.info("Synced governance state for intent #{intent.id}")

        {:error, :no_governance_issue} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to sync governance for intent #{intent.id}: #{inspect(reason)}")
      end
    end)
  end

  defp schedule_sync(interval_ms) do
    Process.send_after(self(), :sync_governance, interval_ms)
  end

  defp result_to_map(%{status: _} = result), do: result

  defp result_to_map(result) when is_struct(result) do
    Map.from_struct(result)
  end

  defp result_to_map(result) when is_map(result), do: result
  defp result_to_map(result), do: %{output: result}
end
