defmodule Lattice.Intents.Rollback do
  @moduledoc """
  Proposes rollback intents for failed intents that have a rollback strategy.

  Rollback is a **new intent**, not a magic undo button. It goes through the
  same governance pipeline as any other intent. An operator reviews rollback
  actions just like forward actions.

  ## Flow

  1. An intent fails (Runner marks it `:failed`)
  2. If `rollback_strategy` is non-nil and auto-rollback is enabled,
     `propose_rollback/1` creates a new `:maintenance` intent
  3. The rollback intent carries `rollback_for` pointing to the original
  4. The rollback intent goes through normal pipeline (classify → gate → approve)
  5. Classification defaults to `:controlled` (rollbacks mutate state)

  ## Configuration

      config :lattice, :intents, auto_propose_rollback: true
  """

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store

  @doc """
  Propose a rollback intent for a failed intent.

  Creates a new `:maintenance` intent with:
  - `rollback_for` pointing to the failed intent's ID
  - `source: %{type: :system, id: "auto-rollback"}`
  - `affected_resources` copied from the original
  - `payload` derived from the rollback strategy

  Returns `{:ok, rollback_intent}` or `{:error, reason}`.

  ## Errors

  - `{:error, :no_rollback_strategy}` — the intent has no rollback strategy
  - `{:error, {:not_failed, state}}` — the intent is not in `:failed` state
  """
  @spec propose_rollback(Intent.t()) :: {:ok, Intent.t()} | {:error, term()}
  def propose_rollback(%Intent{state: :failed, rollback_strategy: nil}) do
    {:error, :no_rollback_strategy}
  end

  def propose_rollback(%Intent{state: :failed, rollback_strategy: strategy} = intent) do
    with {:ok, rollback_intent} <- build_rollback_intent(intent, strategy),
         {:ok, proposed} <- Pipeline.propose(rollback_intent),
         :ok <- store_reverse_link(intent.id, proposed.id) do
      emit_telemetry(intent, proposed)
      {:ok, proposed}
    end
  end

  def propose_rollback(%Intent{state: state}) do
    {:error, {:not_failed, state}}
  end

  @doc """
  Returns `true` if auto-rollback proposal on failure is enabled.
  """
  @spec auto_propose_enabled?() :: boolean()
  def auto_propose_enabled? do
    :lattice
    |> Application.get_env(:intents, [])
    |> Keyword.get(:auto_propose_rollback, false)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp build_rollback_intent(intent, strategy) do
    Intent.new_maintenance(
      %{type: :system, id: "auto-rollback"},
      summary: "Rollback: #{intent.summary}",
      payload: %{
        "rollback_strategy" => strategy,
        "original_intent_id" => intent.id,
        "original_payload" => intent.payload
      },
      metadata: %{rollback_for: intent.id},
      rollback_for: intent.id,
      affected_resources: intent.affected_resources,
      expected_side_effects: ["rollback of #{intent.id}"]
    )
  end

  defp store_reverse_link(original_id, rollback_id) do
    case Store.get(original_id) do
      {:ok, original} ->
        metadata = Map.put(original.metadata, :rollback_intent_id, rollback_id)

        case Store.update(original_id, %{metadata: metadata}) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp emit_telemetry(original, rollback) do
    :telemetry.execute(
      [:lattice, :intent, :rollback_proposed],
      %{system_time: System.system_time()},
      %{original_intent: original, rollback_intent: rollback}
    )
  end
end
