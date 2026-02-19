defmodule Lattice.Planning.Executor do
  @moduledoc """
  Converts approved plans into executable child intents.

  When an `issue_triage` intent's plan is approved, the Executor creates
  individual action intents for each plan step, linking them back to the
  parent intent via metadata.

  ## Flow

  1. Parent intent (issue_triage) has a plan attached and is approved
  2. Executor creates child action intents for each executable step
  3. Child intents reference parent via `metadata.parent_intent_id`
  4. Progress is tracked: when all children complete, parent can complete
  """

  require Logger

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Plan
  alias Lattice.Intents.Store

  @doc """
  Execute a plan by creating child intents for each step.

  Returns `{:ok, child_intents}` or `{:error, reason}`.
  """
  @spec execute_plan(Intent.t()) :: {:ok, [Intent.t()]} | {:error, term()}
  def execute_plan(%Intent{plan: nil}), do: {:error, :no_plan}

  def execute_plan(%Intent{plan: %Plan{} = plan, id: parent_id} = intent) do
    children =
      plan.steps
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {step, idx}, acc ->
        case create_child_intent(intent, step, idx, parent_id) do
          {:ok, child} -> {:cont, acc ++ [child]}
          {:error, reason} -> {:halt, {:error, {reason, step.description}}}
        end
      end)

    case children do
      {:error, _} = error ->
        error

      child_list when is_list(child_list) ->
        Logger.info("Created #{length(child_list)} child intents for plan #{parent_id}")
        {:ok, child_list}
    end
  end

  @doc """
  Check if all child intents for a parent are completed.
  """
  @spec all_children_completed?(String.t()) :: boolean()
  def all_children_completed?(parent_intent_id) do
    case list_children(parent_intent_id) do
      [] ->
        false

      children ->
        Enum.all?(children, fn c ->
          c.state in [:completed, :rejected, :cancelled]
        end)
    end
  end

  @doc """
  List child intents for a parent intent.
  """
  @spec list_children(String.t()) :: [Intent.t()]
  def list_children(parent_intent_id) do
    {:ok, intents} = Store.list()

    Enum.filter(intents, fn i ->
      get_in(i.metadata, ["parent_intent_id"]) == parent_intent_id ||
        get_in(i.metadata, [:parent_intent_id]) == parent_intent_id
    end)
  end

  @doc """
  Compute progress summary for a parent's children.
  """
  @spec progress(String.t()) :: %{
          total: non_neg_integer(),
          completed: non_neg_integer(),
          running: non_neg_integer(),
          pending: non_neg_integer(),
          failed: non_neg_integer(),
          percent: float()
        }
  def progress(parent_intent_id) do
    children = list_children(parent_intent_id)
    total = length(children)
    completed = Enum.count(children, &(&1.state == :completed))
    running = Enum.count(children, &(&1.state == :running))
    failed = Enum.count(children, &(&1.state in [:rejected, :cancelled]))
    pending = total - completed - running - failed

    percent = if total > 0, do: completed / total * 100.0, else: 0.0

    %{
      total: total,
      completed: completed,
      running: running,
      pending: pending,
      failed: failed,
      percent: Float.round(percent, 1)
    }
  end

  # ── Private ─────────────────────────────────────────────────────

  defp create_child_intent(%Intent{} = parent, step, index, parent_id) do
    {:ok, intent} =
      Intent.new_action(parent.source,
        summary: step.description,
        payload:
          Map.merge(parent.payload || %{}, %{
            "step_index" => index,
            "step_id" => step.id,
            "parent_plan_title" => parent.plan.title
          }),
        affected_resources: parent.affected_resources || ["code"],
        expected_side_effects: parent.expected_side_effects || ["code_change"]
      )

    intent = %{
      intent
      | metadata:
          Map.merge(intent.metadata || %{}, %{
            "parent_intent_id" => parent_id,
            "step_index" => index
          })
    }

    Pipeline.propose(intent)
  end
end
