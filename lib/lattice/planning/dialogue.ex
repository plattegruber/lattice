defmodule Lattice.Planning.Dialogue do
  @moduledoc """
  Generates structured clarifying questions for ambiguous intents and
  manages the planning dialogue flow.

  The dialogue engine analyzes intent payloads and determines what
  information is missing before execution can proceed. It produces
  structured questions (not free-form) with predefined option sets.

  ## Flow

  1. Intent arrives (e.g., `issue_triage`)
  2. Dialogue analyzes payload → generates questions
  3. Questions are posted (GitHub comment, API response)
  4. Answers arrive → context updated
  5. When all answered → plan is generated
  6. Plan approval → child action intents created

  ## Question Categories

  - `:scope` — what should be included/excluded
  - `:environment` — target environment for changes
  - `:priority` — urgency and ordering
  - `:approach` — implementation strategy
  - `:risk` — risk tolerance and rollback needs
  """

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Plan
  alias Lattice.Planning.Context

  @type question :: %{
          category: atom(),
          text: String.t(),
          options: [String.t()]
        }

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Analyze an intent and generate clarifying questions.

  Returns a list of questions that should be answered before proceeding
  with plan generation.
  """
  @spec analyze(Intent.t()) :: [question()]
  def analyze(%Intent{} = intent) do
    []
    |> maybe_ask_scope(intent)
    |> maybe_ask_environment(intent)
    |> maybe_ask_approach(intent)
    |> maybe_ask_risk(intent)
  end

  @doc """
  Apply generated questions to the intent's planning context.
  Returns the updated context.
  """
  @spec ask_questions(String.t(), [question()]) :: Context.t()
  def ask_questions(intent_id, questions) do
    Enum.reduce(questions, Context.get(intent_id), fn q, _ctx ->
      Context.add_question(intent_id, q.text, q.options)
    end)
  end

  @doc """
  Generate a plan from an intent and its (fully answered) context.
  Returns a Plan struct suitable for attaching to the intent.
  """
  @spec generate_plan(Intent.t(), Context.t()) :: {:ok, Plan.t()} | {:error, term()}
  def generate_plan(%Intent{} = intent, %Context{} = ctx) do
    if Context.all_answered?(ctx) do
      steps = build_plan_steps(intent, ctx)
      title = plan_title(intent)
      Plan.new(title, steps, :system)
    else
      {:error, :unanswered_questions}
    end
  end

  @doc """
  Check if an intent needs clarification before planning.
  """
  @spec needs_clarification?(Intent.t()) :: boolean()
  def needs_clarification?(%Intent{} = intent) do
    analyze(intent) != []
  end

  # ── Question Generation ─────────────────────────────────────────

  defp maybe_ask_scope(questions, %Intent{payload: payload}) when is_map(payload) do
    has_scope =
      Map.has_key?(payload, "scope") || Map.has_key?(payload, :scope) ||
        Map.has_key?(payload, "affected_files") || Map.has_key?(payload, :affected_files)

    if has_scope do
      questions
    else
      questions ++
        [
          %{
            category: :scope,
            text: "What is the scope of this change?",
            options: [
              "Single file/module",
              "Multiple files in one directory",
              "Cross-cutting (multiple directories)",
              "Full codebase"
            ]
          }
        ]
    end
  end

  defp maybe_ask_scope(questions, _), do: questions

  defp maybe_ask_environment(questions, %Intent{payload: payload}) when is_map(payload) do
    has_env =
      Map.has_key?(payload, "environment") || Map.has_key?(payload, :environment) ||
        Map.has_key?(payload, "target_env") || Map.has_key?(payload, :target_env)

    kind_needs_env = Map.get(payload, "capability") in ["fly", "deploy"]

    if has_env || !kind_needs_env do
      questions
    else
      questions ++
        [
          %{
            category: :environment,
            text: "Which environment should this target?",
            options: ["Development", "Staging", "Production"]
          }
        ]
    end
  end

  defp maybe_ask_environment(questions, _), do: questions

  defp maybe_ask_approach(questions, %Intent{kind: :issue_triage, payload: payload})
       when is_map(payload) do
    has_approach = Map.has_key?(payload, "approach") || Map.has_key?(payload, :approach)

    if has_approach do
      questions
    else
      questions ++
        [
          %{
            category: :approach,
            text: "What approach should be taken?",
            options: [
              "Quick fix (minimal changes)",
              "Thorough refactor",
              "New implementation",
              "Investigation only"
            ]
          }
        ]
    end
  end

  defp maybe_ask_approach(questions, _), do: questions

  defp maybe_ask_risk(questions, %Intent{payload: payload} = intent) when is_map(payload) do
    has_risk_info =
      Map.has_key?(payload, "rollback_strategy") ||
        Map.has_key?(payload, :rollback_strategy) ||
        Map.has_key?(payload, "risk_tolerance") ||
        Map.has_key?(payload, :risk_tolerance)

    if has_risk_info || !has_side_effects?(intent) do
      questions
    else
      questions ++
        [
          %{
            category: :risk,
            text: "What is the risk tolerance for this change?",
            options: [
              "Low (safe changes only, full rollback plan)",
              "Medium (some risk acceptable, rollback available)",
              "High (speed over safety, manual rollback ok)"
            ]
          }
        ]
    end
  end

  defp maybe_ask_risk(questions, _), do: questions

  # ── Plan Generation ─────────────────────────────────────────────

  defp plan_title(%Intent{summary: summary}) when is_binary(summary) do
    "Plan: #{summary}"
  end

  defp plan_title(%Intent{kind: kind}) do
    "Plan: #{kind}"
  end

  defp build_plan_steps(%Intent{kind: :issue_triage} = intent, ctx) do
    base_steps = [
      [description: "Analyze issue requirements"],
      [description: "Identify affected files and modules"],
      [description: "Implement changes"]
    ]

    approach = find_answer(ctx, :approach)

    approach_steps =
      case approach do
        "Investigation only" ->
          [[description: "Document findings and recommendations"]]

        "Thorough refactor" ->
          [
            [description: "Write tests for existing behavior"],
            [description: "Refactor implementation"],
            [description: "Verify tests pass"]
          ]

        _ ->
          [[description: "Write or update tests"], [description: "Verify tests pass"]]
      end

    review_steps =
      if has_side_effects?(intent) do
        [[description: "Review side effects and rollback plan"], [description: "Create PR"]]
      else
        [[description: "Create PR"]]
      end

    base_steps ++ approach_steps ++ review_steps
  end

  defp build_plan_steps(%Intent{} = _intent, _ctx) do
    [
      [description: "Analyze requirements"],
      [description: "Implement changes"],
      [description: "Run tests"],
      [description: "Create PR"]
    ]
  end

  defp find_answer(%Context{exchanges: exchanges}, category) do
    Enum.find_value(exchanges, fn ex ->
      if String.contains?(ex.question, to_string(category)), do: ex.answer
    end)
  end

  defp has_side_effects?(%Intent{expected_side_effects: effects})
       when is_list(effects) and effects != [] do
    effects != ["none"]
  end

  defp has_side_effects?(_), do: false
end
