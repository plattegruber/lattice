defmodule Lattice.Intents.Executor.PrFixup do
  @moduledoc """
  Executor that addresses PR review feedback via sprite runs.

  When a `pr_fixup` intent is approved, this executor:

  1. Extracts the PR number and feedback from the intent payload
  2. Fetches the latest reviews and review comments from GitHub
  3. Parses feedback into actionable items via `FeedbackParser`
  4. Builds a bash script that checks out the PR branch and applies fixes
  5. Executes on a sprite via `Sprites.exec/2`
  6. Returns the result with any new commit artifacts

  ## Routing

  This executor claims intents where `kind == :pr_fixup` and the payload
  contains `pr_url` and `feedback`.
  """

  @behaviour Lattice.Intents.Executor

  require Logger

  alias Lattice.Capabilities.GitHub
  alias Lattice.Capabilities.GitHub.FeedbackParser
  alias Lattice.Capabilities.Sprites
  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Intent

  @pr_url_pattern ~r{github\.com/([^/]+/[^/]+)/pull/(\d+)}

  # ── Executor Callbacks ─────────────────────────────────────────────

  @impl Lattice.Intents.Executor
  def can_execute?(%Intent{kind: :pr_fixup, payload: payload}) do
    Map.has_key?(payload, "pr_url") and Map.has_key?(payload, "feedback")
  end

  def can_execute?(_intent), do: false

  @impl Lattice.Intents.Executor
  def execute(%Intent{} = intent) do
    started_at = DateTime.utc_now()
    start_mono = System.monotonic_time(:millisecond)

    with {:ok, pr_info} <- extract_pr_info(intent),
         {:ok, feedback} <- gather_feedback(pr_info),
         {:ok, sprite_name} <- resolve_sprite(intent),
         {:ok, script} <- build_fixup_script(pr_info, feedback, intent),
         {:ok, output} <- run_on_sprite(sprite_name, script) do
      duration_ms = System.monotonic_time(:millisecond) - start_mono
      completed_at = DateTime.utc_now()

      artifacts = extract_artifacts(output, pr_info)

      ExecutionResult.success(duration_ms, started_at, completed_at,
        output: output,
        artifacts: artifacts,
        executor: __MODULE__
      )
    else
      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_mono
        completed_at = DateTime.utc_now()

        Logger.warning("PR fixup execution failed: #{inspect(reason)}")

        ExecutionResult.failure(duration_ms, started_at, completed_at,
          error: reason,
          executor: __MODULE__
        )
    end
  end

  # ── Private ────────────────────────────────────────────────────────

  defp extract_pr_info(%Intent{payload: payload}) do
    pr_url = Map.fetch!(payload, "pr_url")

    case Regex.run(@pr_url_pattern, pr_url) do
      [_, repo, number_str] ->
        {:ok,
         %{
           repo: repo,
           number: String.to_integer(number_str),
           url: pr_url,
           feedback_text: Map.get(payload, "feedback", ""),
           reviewer: Map.get(payload, "reviewer"),
           pr_title: Map.get(payload, "pr_title", "PR ##{number_str}")
         }}

      _ ->
        {:error, {:invalid_pr_url, pr_url}}
    end
  end

  defp gather_feedback(%{number: pr_number} = pr_info) do
    reviews = fetch_reviews(pr_number)
    comments = fetch_review_comments(pr_number)
    signals = FeedbackParser.parse_reviews(reviews, comments)
    action_items = FeedbackParser.extract_action_items(comments)
    by_file = FeedbackParser.group_by_file(comments)

    {:ok,
     %{
       signals: signals,
       action_items: action_items,
       by_file: by_file,
       raw_feedback: pr_info.feedback_text,
       reviewer: pr_info.reviewer
     }}
  end

  defp fetch_reviews(pr_number) do
    case GitHub.list_reviews(pr_number) do
      {:ok, reviews} ->
        reviews

      {:error, reason} ->
        Logger.warning("Failed to fetch reviews for PR ##{pr_number}: #{inspect(reason)}")
        []
    end
  end

  defp fetch_review_comments(pr_number) do
    case GitHub.list_review_comments(pr_number) do
      {:ok, comments} ->
        comments

      {:error, reason} ->
        Logger.warning("Failed to fetch review comments for PR ##{pr_number}: #{inspect(reason)}")
        []
    end
  end

  defp resolve_sprite(%Intent{payload: payload}) do
    case Map.get(payload, "sprite_name") do
      nil ->
        # Fall back to first available sprite from fleet config
        sprites = Application.get_env(:lattice, :fleet, []) |> Keyword.get(:sprites, [])

        case sprites do
          [first | _] -> {:ok, first}
          [] -> {:error, :no_sprite_available}
        end

      name ->
        {:ok, name}
    end
  end

  defp build_fixup_script(pr_info, feedback, _intent) do
    %{repo: repo, number: pr_number} = pr_info
    feedback_summary = format_feedback_summary(feedback)

    script = """
    set -euo pipefail

    # Checkout the PR branch
    cd /workspace 2>/dev/null || cd /tmp
    if [ -d "fixup-repo" ]; then rm -rf fixup-repo; fi
    gh repo clone #{escape(repo)} fixup-repo -- --depth=50
    cd fixup-repo

    # Fetch and checkout the PR branch
    gh pr checkout #{pr_number}

    # Write feedback context for the coding agent
    mkdir -p .lattice
    cat > .lattice/fixup-context.md << 'FIXUP_EOF'
    # PR Fixup Context

    ## PR: #{escape(pr_info.pr_title)} (##{pr_number})

    ## Review Feedback
    #{feedback_summary}

    ## Instructions
    Address the review feedback above. Make the minimal changes needed to resolve
    each item. Commit your changes with a clear message referencing the feedback.
    FIXUP_EOF

    echo "FIXUP_CONTEXT_WRITTEN"
    echo "PR_NUMBER=#{pr_number}"
    echo "REPO=#{escape(repo)}"
    """

    {:ok, script}
  end

  defp format_feedback_summary(%{raw_feedback: raw, action_items: items, by_file: by_file}) do
    parts = [raw]
    file_parts = format_file_feedback(by_file)
    item_parts = format_action_items(items)

    Enum.join(parts ++ file_parts ++ item_parts, "\n\n")
  end

  defp format_file_feedback(by_file) do
    Enum.map(by_file, fn {path, comments} ->
      comment_text = Enum.map_join(comments, "\n", fn c -> "  - #{c.body}" end)
      "### #{path}\n#{comment_text}"
    end)
  end

  defp format_action_items([]), do: []

  defp format_action_items(items) do
    ["### Action Items"] ++
      Enum.map(items, fn c ->
        location = if c.path, do: " (#{c.path}:#{c.line})", else: ""
        "- #{c.body}#{location}"
      end)
  end

  defp run_on_sprite(sprite_name, script) do
    case Sprites.exec(sprite_name, script) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, {:sprite_exec_failed, reason}}
    end
  end

  defp extract_artifacts(output, pr_info) do
    base = [%{type: "pr_fixup", data: %{pr_number: pr_info.number, repo: pr_info.repo}}]

    # Extract commit SHA if present in output
    commit_artifacts =
      case Regex.run(~r/\b([0-9a-f]{40})\b/, output || "") do
        [_, sha] -> [%{type: "commit", data: sha}]
        _ -> []
      end

    base ++ commit_artifacts
  end

  defp escape(str) when is_binary(str) do
    str
    |> String.replace("'", "'\\''")
    |> String.replace("`", "\\`")
    |> String.replace("$", "\\$")
  end

  defp escape(nil), do: ""
end
