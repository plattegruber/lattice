defmodule Lattice.Capabilities.GitHub.Comments do
  @moduledoc """
  Structured comment templates for GitHub-based human-in-the-loop governance.

  Renders machine-parseable Markdown comments with sentinel markers (HTML
  comments invisible to GitHub users). These enable Lattice to both post
  structured information and later read back responses.

  ## Sentinel Markers

  Each comment type includes a sentinel like:

      <!-- lattice:question intent_id=int_xxx -->

  These are parsed by `Lattice.Capabilities.GitHub.Comments.Parser`.
  """

  alias Lattice.Intents.Intent

  @doc """
  Render a question comment for an intent in `:waiting_for_input` state.

  The `questions` parameter should be a list of maps with `:text` keys,
  or a single map with a `:text` key for a single question.
  """
  @spec question_comment(Intent.t(), list() | map()) :: String.t()
  def question_comment(%Intent{} = intent, questions) do
    questions = List.wrap(questions)

    question_list =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {q, i} ->
        text = extract_question_text(q)
        "- [ ] **#{i}.** #{text}"
      end)

    """
    ## Lattice needs your input

    **Intent:** `#{intent.id}` — #{intent.summary || "No summary"}

    #{question_list}

    **How to respond:** Reply to this comment with your answers. Check the boxes above or write your response below.

    #{sentinel(:question, intent)}
    _Posted by Lattice._\
    """
    |> String.trim()
  end

  @doc """
  Render a plan comment showing the proposed execution plan.
  """
  @spec plan_comment(Intent.t(), map() | nil) :: String.t()
  def plan_comment(%Intent{} = intent, plan) when not is_nil(plan) do
    plan_body =
      if is_binary(plan.rendered_markdown) and plan.rendered_markdown != "" do
        plan.rendered_markdown
      else
        render_plan_steps(plan)
      end

    version = Map.get(plan, :version, 1)

    """
    ## Proposed Execution Plan

    **Intent:** `#{intent.id}` — #{intent.summary || "No summary"}

    #{plan_body}

    **To approve:** Add the `intent-approved` label to this issue.
    **To reject:** Add the `intent-rejected` label.

    #{sentinel(:plan, intent, version: version)}
    _Posted by Lattice._\
    """
    |> String.trim()
  end

  @doc """
  Render an execution summary comment with outcome, duration, and artifacts.
  """
  @spec summary_comment(Intent.t(), map()) :: String.t()
  def summary_comment(%Intent{} = intent, result) do
    status = Map.get(result, :status, :unknown)
    status_label = status_emoji(status)
    duration = format_duration(Map.get(result, :duration_ms))

    output_section = format_output(result)
    artifacts_section = format_artifacts(intent)

    """
    ## Execution #{status_label}

    **Intent:** `#{intent.id}` — #{intent.summary || "No summary"}
    **Duration:** #{duration}

    #{output_section}#{artifacts_section}
    #{sentinel(:summary, intent)}
    _Posted by Lattice._\
    """
    |> String.trim()
  end

  @doc """
  Render a progress update comment showing current plan step.
  """
  @spec progress_comment(Intent.t(), map()) :: String.t()
  def progress_comment(%Intent{} = intent, update) do
    current_step = Map.get(update, :current_step, "?")
    total_steps = Map.get(update, :total_steps, "?")
    message = Map.get(update, :message, "Execution in progress.")

    """
    ## Progress Update

    **Intent:** `#{intent.id}`
    **Step:** #{current_step} of #{total_steps}

    #{message}

    #{sentinel(:progress, intent)}
    _Posted by Lattice._\
    """
    |> String.trim()
  end

  # ── Private: Question Helpers ──────────────────────────────────────

  defp extract_question_text(%{text: text}), do: text
  defp extract_question_text(%{"text" => text}), do: text
  defp extract_question_text(text) when is_binary(text), do: text
  defp extract_question_text(other), do: inspect(other)

  # ── Private: Sentinel Markers ─────────────────────────────────────

  defp sentinel(type, %Intent{id: id}, opts \\ []) do
    extra =
      opts
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    extra_str = if extra == "", do: "", else: " #{extra}"
    "<!-- lattice:#{type} intent_id=#{id}#{extra_str} -->"
  end

  # ── Private: Plan Rendering ───────────────────────────────────────

  defp render_plan_steps(%{steps: steps}) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {step, i} ->
      skill = if step.skill, do: " `#{step.skill}`", else: ""
      checkbox = step_checkbox(step.status)
      "#{i}. #{checkbox} #{step.description}#{skill}"
    end)
  end

  defp render_plan_steps(_), do: "_No steps defined._"

  defp step_checkbox(:completed), do: "[x]"
  defp step_checkbox(:running), do: "[~]"
  defp step_checkbox(:failed), do: "[!]"
  defp step_checkbox(:skipped), do: "[-]"
  defp step_checkbox(_), do: "[ ]"

  # ── Private: Summary Helpers ──────────────────────────────────────

  defp status_emoji(:success), do: "Completed"
  defp status_emoji(:failure), do: "Failed"
  defp status_emoji(_), do: "Outcome"

  defp format_duration(nil), do: "N/A"
  defp format_duration(ms) when is_number(ms) and ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(_), do: "N/A"

  defp format_output(result) do
    cond do
      Map.has_key?(result, :error) and result.error != nil ->
        "### Error\n\n```\n#{inspect(result.error, pretty: true, limit: 500)}\n```\n\n"

      Map.has_key?(result, :output) and result.output != nil ->
        "### Output\n\n```\n#{inspect(result.output, pretty: true, limit: 500)}\n```\n\n"

      true ->
        ""
    end
  end

  defp format_artifacts(%Intent{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :artifacts) do
      artifacts when is_list(artifacts) and artifacts != [] ->
        items = Enum.map_join(artifacts, "\n", &format_artifact_item/1)
        "### Artifacts\n\n#{items}\n\n"

      _ ->
        ""
    end
  end

  defp format_artifacts(_), do: ""

  defp format_artifact_item(artifact) do
    label = Map.get(artifact, :label, Map.get(artifact, :type, "artifact"))
    url = Map.get(artifact, :url)

    if url, do: "- [#{label}](#{url})", else: "- #{label}"
  end
end
