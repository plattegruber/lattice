defmodule Lattice.Intents.Pipeline do
  @moduledoc """
  Advances intents through their lifecycle: proposal, classification, gating,
  and approval.

  The Pipeline is the core control flow that ensures no intent executes without
  classification and governance. Every intent must pass through the
  classify-gate pipeline before it can reach `:approved`.

  ## Flow

      propose/1 → persist → classify/1 → gate/1
        SAFE:       proposed → classified → approved
        CONTROLLED: proposed → classified → awaiting_approval
        DANGEROUS:  proposed → classified → awaiting_approval

  ## Events

  Each transition emits:
  - A Telemetry event (`[:lattice, :intent, <state>]`)
  - A PubSub broadcast on `"intents:<intent_id>"` and `"intents:all"`

  ## Classification Mapping

  Intent kinds map to `Safety.Action` structs:
  - `:action` — uses `payload["capability"]` and `payload["operation"]`
  - `:inquiry` — always `:controlled` (requests human input)
  - `:maintenance` — always `:safe` (proposes improvements)
  """

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store
  alias Lattice.Safety.Action
  alias Lattice.Safety.Classifier
  alias Lattice.Safety.Gate

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Propose a new intent, persist it, classify it, and gate it.

  Creates the intent in `:proposed` state via the IntentStore, then
  auto-advances through classification and gating. SAFE intents reach
  `:approved` without human intervention. CONTROLLED and DANGEROUS
  intents stop at `:awaiting_approval`.

  Returns `{:ok, intent}` with the intent in its final resting state.
  """
  @spec propose(Intent.t()) :: {:ok, Intent.t()} | {:error, term()}
  def propose(%Intent{state: :proposed} = intent) do
    with {:ok, stored} <- Store.create(intent) do
      emit_telemetry([:lattice, :intent, :proposed], stored)
      broadcast(stored, {:intent_proposed, stored})
      classify(stored.id)
    end
  end

  @doc """
  Classify an intent by mapping its kind and payload to a safety level.

  Transitions the intent from `:proposed` to `:classified`, stores the
  classification result, then auto-advances through gating.

  Returns `{:ok, intent}` with the intent in its post-gating state.
  """
  @spec classify(String.t()) :: {:ok, Intent.t()} | {:error, term()}
  def classify(intent_id) when is_binary(intent_id) do
    with {:ok, intent} <- Store.get(intent_id),
         {:ok, classification} <- classify_intent(intent),
         {:ok, classified} <-
           Store.update(intent_id, %{
             state: :classified,
             classification: classification,
             actor: :pipeline,
             reason: "auto-classified as #{classification}"
           }) do
      emit_telemetry([:lattice, :intent, :classified], classified)
      broadcast(classified, {:intent_classified, classified})
      gate(intent_id)
    end
  end

  @doc """
  Gate an intent based on its classification level.

  SAFE intents auto-advance to `:approved`. CONTROLLED and DANGEROUS
  intents transition to `:awaiting_approval` for human review.

  Task intents targeting repos on the allowlist auto-approve even when
  classified as `:controlled`.

  Returns `{:ok, intent}` in its final resting state.
  """
  @spec gate(String.t()) :: {:ok, Intent.t()} | {:error, term()}
  def gate(intent_id) when is_binary(intent_id) do
    with {:ok, intent} <- Store.get(intent_id),
         {:ok, action} <- build_action(intent) do
      case Gate.check(action) do
        :allow ->
          advance_to_approved(intent_id)

        {:deny, :approval_required} ->
          gate_approval_required(intent_id, intent)

        {:deny, :action_not_permitted} ->
          reject_not_permitted(intent_id)
      end
    end
  end

  @doc """
  Approve an intent that is awaiting approval.

  Transitions from `:awaiting_approval` to `:approved`. The actor who
  approved the intent is tracked in the transition log.

  ## Options

  - `:actor` — (required) who approved the intent
  - `:reason` — why the intent was approved
  """
  @spec approve(String.t(), keyword()) :: {:ok, Intent.t()} | {:error, term()}
  def approve(intent_id, opts \\ []) when is_binary(intent_id) do
    actor = Keyword.get(opts, :actor)
    reason = Keyword.get(opts, :reason, "approved")

    with {:ok, approved} <-
           Store.update(intent_id, %{
             state: :approved,
             actor: actor,
             reason: reason
           }) do
      emit_telemetry([:lattice, :intent, :approved], approved)
      broadcast(approved, {:intent_approved, approved})
      {:ok, approved}
    end
  end

  @doc """
  Reject an intent that is awaiting approval.

  Transitions from `:awaiting_approval` to `:rejected`.

  ## Options

  - `:actor` — (required) who rejected the intent
  - `:reason` — why the intent was rejected
  """
  @spec reject(String.t(), keyword()) :: {:ok, Intent.t()} | {:error, term()}
  def reject(intent_id, opts \\ []) when is_binary(intent_id) do
    actor = Keyword.get(opts, :actor)
    reason = Keyword.get(opts, :reason, "rejected")

    with {:ok, rejected} <-
           Store.update(intent_id, %{
             state: :rejected,
             actor: actor,
             reason: reason
           }) do
      emit_telemetry([:lattice, :intent, :rejected], rejected)
      broadcast(rejected, {:intent_rejected, rejected})
      {:ok, rejected}
    end
  end

  @doc """
  Cancel an intent from any pre-execution state.

  Valid source states: `:proposed`, `:classified`, `:awaiting_approval`,
  `:approved`. Cannot cancel an intent that is already running, completed,
  failed, rejected, or canceled.

  ## Options

  - `:actor` — (required) who canceled the intent
  - `:reason` — why the intent was canceled
  """
  @spec cancel(String.t(), keyword()) :: {:ok, Intent.t()} | {:error, term()}
  def cancel(intent_id, opts \\ []) when is_binary(intent_id) do
    actor = Keyword.get(opts, :actor)
    reason = Keyword.get(opts, :reason, "canceled")

    with {:ok, canceled} <-
           Store.update(intent_id, %{
             state: :canceled,
             actor: actor,
             reason: reason
           }) do
      emit_telemetry([:lattice, :intent, :canceled], canceled)
      broadcast(canceled, {:intent_canceled, canceled})
      {:ok, canceled}
    end
  end

  @doc """
  Attach a structured execution plan to an intent.

  The plan is stored on the intent and the version counter starts at 1.
  Emits `[:lattice, :intent, :plan_attached]` telemetry.
  """
  @spec attach_plan(String.t(), Lattice.Intents.Plan.t()) :: {:ok, Intent.t()} | {:error, term()}
  def attach_plan(intent_id, %Lattice.Intents.Plan{} = plan) when is_binary(intent_id) do
    with {:ok, updated} <- Store.update(intent_id, %{plan: plan}) do
      emit_telemetry([:lattice, :intent, :plan_attached], updated)
      broadcast(updated, {:intent_plan_attached, updated})
      {:ok, updated}
    end
  end

  @doc """
  Update the status of a step within an intent's plan.

  Delegates to `Store.update_plan_step/4`, which bypasses frozen-field checks
  since step status updates are operational.
  """
  @spec update_plan_step(String.t(), String.t(), atom(), term()) ::
          {:ok, Intent.t()} | {:error, term()}
  def update_plan_step(intent_id, step_id, status, output \\ nil) do
    Store.update_plan_step(intent_id, step_id, status, output)
  end

  # ── Classification Mapping ──────────────────────────────────────────

  @doc """
  Map an intent to its safety classification.

  - `:action` intents use the payload's capability/operation to look up
    classification in the Safety.Classifier registry.
  - `:inquiry` intents are always `:controlled` (request human input).
  - `:maintenance` intents are always `:safe` (propose improvements).

  If an action intent's capability/operation is not in the classifier
  registry, defaults to `:controlled` for safety.
  """
  @spec classify_intent(Intent.t()) :: {:ok, Intent.classification()} | {:error, term()}
  def classify_intent(%Intent{kind: :inquiry}), do: {:ok, :controlled}
  def classify_intent(%Intent{kind: :maintenance}), do: {:ok, :safe}

  def classify_intent(%Intent{kind: :action, payload: payload}) do
    capability = payload_atom(payload, "capability")
    operation = payload_atom(payload, "operation")

    case Classifier.classify(capability, operation) do
      {:ok, %Action{classification: classification}} ->
        {:ok, classification}

      {:error, :unknown_action} ->
        # Unknown actions default to controlled for safety
        {:ok, :controlled}
    end
  end

  # ── Private ────────────────────────────────────────────────────────

  defp gate_approval_required(intent_id, intent) do
    if task_on_allowlisted_repo?(intent) do
      advance_to_approved(intent_id, "auto-approved (allowlisted repo)")
    else
      advance_to_awaiting_approval(intent_id)
    end
  end

  defp advance_to_approved(intent_id, reason \\ "auto-approved (safe)") do
    with {:ok, approved} <-
           Store.update(intent_id, %{
             state: :approved,
             actor: :pipeline,
             reason: reason
           }) do
      emit_telemetry([:lattice, :intent, :approved], approved)
      broadcast(approved, {:intent_approved, approved})
      {:ok, approved}
    end
  end

  defp advance_to_awaiting_approval(intent_id) do
    with {:ok, awaiting} <-
           Store.update(intent_id, %{
             state: :awaiting_approval,
             actor: :pipeline,
             reason: "approval required"
           }) do
      emit_telemetry([:lattice, :intent, :awaiting_approval], awaiting)
      broadcast(awaiting, {:intent_awaiting_approval, awaiting})
      {:ok, awaiting}
    end
  end

  defp reject_not_permitted(intent_id) do
    with {:ok, rejected} <-
           Store.update(intent_id, %{
             state: :awaiting_approval,
             actor: :pipeline,
             reason: "action category not permitted"
           }) do
      emit_telemetry([:lattice, :intent, :awaiting_approval], rejected)
      broadcast(rejected, {:intent_awaiting_approval, rejected})
      {:ok, rejected}
    end
  end

  defp build_action(%Intent{classification: classification}) when not is_nil(classification) do
    # Build a synthetic Action struct from the intent's stored classification
    # so the Gate can evaluate it
    Action.new(:intents, :execute, classification)
  end

  defp build_action(_intent), do: {:error, :not_classified}

  defp payload_atom(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_existing_atom(value)
      _ -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  defp task_on_allowlisted_repo?(%Intent{} = intent) do
    Intent.task?(intent) and repo_allowlisted?(intent.payload)
  end

  defp repo_allowlisted?(payload) do
    repo = Map.get(payload, "repo")
    allowlist = task_allowlist_config()

    repo != nil and repo in allowlist
  end

  defp task_allowlist_config do
    :lattice
    |> Application.get_env(:task_allowlist, [])
    |> Keyword.get(:auto_approve_repos, [])
  end

  defp emit_telemetry(event_name, %Intent{} = intent) do
    :telemetry.execute(
      event_name,
      %{system_time: System.system_time()},
      %{intent: intent}
    )
  end

  defp broadcast(%Intent{} = intent, message) do
    Phoenix.PubSub.broadcast(Lattice.PubSub, "intents:#{intent.id}", message)
    Phoenix.PubSub.broadcast(Lattice.PubSub, "intents:all", message)
  end
end
