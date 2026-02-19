defmodule Lattice.Intents.Executor.Runner do
  @moduledoc """
  Orchestrates intent execution: transition, dispatch, and outcome recording.

  The Runner is the integration point between the Pipeline (which approves
  intents) and the Executor (which fulfills them). It:

  1. Transitions the intent from `:approved` to `:running`
  2. Routes to the correct executor via `Executor.Router`
  3. Invokes the executor's `execute/1` callback
  4. Records the outcome (result + artifacts) on the intent
  5. Transitions to `:completed` or `:failed`
  6. Emits telemetry and PubSub events at each stage

  ## Error Isolation

  Execution is wrapped in error handling. If the executor raises an exception,
  the intent is marked `:failed` with the error details. The Runner never
  propagates executor crashes -- intents fail gracefully.

  ## Usage

      {:ok, intent} = Lattice.Intents.Executor.Runner.run(intent_id)
  """

  require Logger

  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Executor.Router
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Rollback
  alias Lattice.Intents.Store

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Execute an approved intent by ID.

  Fetches the intent from the store, transitions it to `:running`, routes it
  to the appropriate executor, and records the outcome.

  Returns `{:ok, intent}` with the intent in its terminal state (`:completed`
  or `:failed`).

  ## Errors

  - `{:error, :not_found}` -- intent does not exist
  - `{:error, {:not_approved, state}}` -- intent is not in `:approved` state
  - `{:error, {:invalid_transition, _}}` -- state machine violation
  """
  @spec run(String.t()) :: {:ok, Intent.t()} | {:error, term()}
  def run(intent_id) when is_binary(intent_id) do
    with {:ok, intent} <- Store.get(intent_id),
         :ok <- validate_approved(intent),
         {:ok, running} <- transition_to_running(intent_id) do
      emit_started(running)

      case Router.route(running) do
        {:ok, executor} ->
          execute_and_record(intent_id, running, executor)

        {:error, :no_executor} ->
          record_crash(intent_id, {:no_executor, running.kind})
      end
    end
  end

  @doc """
  Execute an approved intent by ID with a specific executor module.

  Bypasses the Router and uses the provided executor directly. Useful for
  testing or when the caller knows which executor to use.
  """
  @spec run(String.t(), module()) :: {:ok, Intent.t()} | {:error, term()}
  def run(intent_id, executor) when is_binary(intent_id) and is_atom(executor) do
    with {:ok, intent} <- Store.get(intent_id),
         :ok <- validate_approved(intent),
         {:ok, running} <- transition_to_running(intent_id) do
      emit_started(running)
      execute_and_record(intent_id, running, executor)
    end
  end

  # ── Private ────────────────────────────────────────────────────────

  defp validate_approved(%Intent{state: :approved}), do: :ok
  defp validate_approved(%Intent{state: state}), do: {:error, {:not_approved, state}}

  defp transition_to_running(intent_id) do
    Store.update(intent_id, %{
      state: :running,
      actor: :executor,
      reason: "execution started"
    })
  end

  defp execute_and_record(intent_id, intent, executor) do
    case safe_execute(executor, intent) do
      {:ok, %ExecutionResult{status: :success} = result} ->
        record_success(intent_id, result)

      {:ok, %ExecutionResult{status: :failure} = result} ->
        record_failure(intent_id, result)

      {:error, reason} ->
        record_crash(intent_id, reason)
    end
  end

  defp safe_execute(executor, intent) do
    executor.execute(intent)
  rescue
    exception ->
      {:error, {:executor_crash, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:executor_crash, {kind, reason}}}
  end

  defp record_success(intent_id, %ExecutionResult{} = result) do
    record_artifacts(intent_id, result.artifacts)

    case Store.update(intent_id, %{
           state: :completed,
           result: result_to_map(result),
           actor: :executor,
           reason: "execution completed successfully"
         }) do
      {:ok, completed} ->
        emit_completed(completed, result)
        {:ok, completed}

      {:error, _} = error ->
        error
    end
  end

  defp record_failure(intent_id, %ExecutionResult{} = result) do
    record_artifacts(intent_id, result.artifacts)

    case Store.update(intent_id, %{
           state: :failed,
           result: result_to_map(result),
           actor: :executor,
           reason: "execution failed: #{inspect(result.error)}"
         }) do
      {:ok, failed} ->
        emit_failed(failed, result.error)
        maybe_propose_rollback(failed)
        {:ok, failed}

      {:error, _} = error ->
        error
    end
  end

  defp record_crash(intent_id, reason) do
    now = DateTime.utc_now()

    {:ok, crash_result} =
      ExecutionResult.failure(0, now, now, error: reason, executor: :crashed)

    case Store.update(intent_id, %{
           state: :failed,
           result: result_to_map(crash_result),
           actor: :executor,
           reason: "executor crashed: #{inspect(reason)}"
         }) do
      {:ok, failed} ->
        emit_failed(failed, reason)
        maybe_propose_rollback(failed)
        {:ok, failed}

      {:error, _} = error ->
        Logger.error("Failed to record executor crash for intent #{intent_id}: #{inspect(error)}")
        error
    end
  end

  defp record_artifacts(intent_id, artifacts) when is_list(artifacts) do
    Enum.each(artifacts, fn artifact ->
      Store.add_artifact(intent_id, artifact)
    end)
  end

  defp result_to_map(%ExecutionResult{} = result) do
    %{
      status: result.status,
      output: result.output,
      error: result.error,
      duration_ms: result.duration_ms,
      started_at: result.started_at,
      completed_at: result.completed_at,
      executor: result.executor,
      artifact_count: length(result.artifacts)
    }
  end

  defp maybe_propose_rollback(%Intent{rollback_strategy: nil}), do: :ok
  defp maybe_propose_rollback(%Intent{rollback_for: existing}) when not is_nil(existing), do: :ok

  defp maybe_propose_rollback(%Intent{} = failed) do
    if Rollback.auto_propose_enabled?() do
      case Rollback.propose_rollback(failed) do
        {:ok, rollback} ->
          Logger.info("Proposed rollback intent #{rollback.id} for failed intent #{failed.id}")

        {:error, reason} ->
          Logger.warning("Failed to propose rollback for intent #{failed.id}: #{inspect(reason)}")
      end
    end
  end

  # ── Event Emission ────────────────────────────────────────────────

  defp emit_started(%Intent{} = intent) do
    emit_telemetry([:lattice, :intent, :execution, :started], %{intent: intent})
    broadcast(intent, {:intent_execution_started, intent})
  end

  defp emit_completed(%Intent{} = intent, %ExecutionResult{} = result) do
    emit_telemetry([:lattice, :intent, :execution, :completed], %{
      intent: intent,
      result: result
    })

    broadcast(intent, {:intent_execution_completed, intent, result})
  end

  defp emit_failed(%Intent{} = intent, error) do
    emit_telemetry([:lattice, :intent, :execution, :failed], %{
      intent: intent,
      error: error
    })

    broadcast(intent, {:intent_execution_failed, intent, error})
  end

  defp emit_telemetry(event_name, metadata) do
    :telemetry.execute(
      event_name,
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp broadcast(%Intent{} = intent, message) do
    Phoenix.PubSub.broadcast(Lattice.PubSub, "intents:#{intent.id}", message)
    Phoenix.PubSub.broadcast(Lattice.PubSub, "intents:all", message)
  end
end
