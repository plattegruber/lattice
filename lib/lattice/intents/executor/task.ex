defmodule Lattice.Intents.Executor.Task do
  @moduledoc """
  Executor that runs tasks on sprites via the Sprites exec API.

  The Task executor handles task intents -- action intents with a structured
  payload targeting a sprite for work that produces artifacts (like a PR URL).
  It builds an inline bash script, sends it to the sprite via the exec
  capability, captures stdout, and extracts artifacts (PR URLs).

  ## Routing

  Task intents are identified by `Intent.task?/1` returning `true`:
  kind == `:action`, capability == `"sprites"`, operation == `"run_task"`.

  This executor is registered before `Executor.Sprite` in the Router because
  task intents are a more specific subset of sprite-sourced action intents.

  ## Script Execution

  The executor builds an inline bash script from the payload fields and sends
  it to the sprite via `Sprites.exec/2`. The script:

  1. Clones the target repo
  2. Creates a feature branch
  3. Makes the requested change
  4. Commits and pushes
  5. Opens a PR via `gh`
  6. Prints JSON with the `pr_url`

  ## Artifacts

  After execution, stdout is parsed for a GitHub PR URL. If found, a
  `%{type: "pr_url", data: url}` artifact is included in the result.
  """

  @behaviour Lattice.Intents.Executor

  require Logger

  alias Lattice.Capabilities.GitHub.ArtifactLink
  alias Lattice.Capabilities.GitHub.ArtifactRegistry
  alias Lattice.Capabilities.Sprites
  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Intent
  alias Lattice.Protocol.TaskPayload

  @pr_url_pattern ~r{https://github\.com/[^\s"']+/pull/\d+}

  # ── Executor Callbacks ─────────────────────────────────────────────

  @impl Lattice.Intents.Executor
  def can_execute?(%Intent{} = intent) do
    Intent.task?(intent)
  end

  @impl Lattice.Intents.Executor
  def execute(%Intent{} = intent) do
    started_at = DateTime.utc_now()
    start_mono = System.monotonic_time(:millisecond)

    sprite_name = Map.fetch!(intent.payload, "sprite_name")

    # Build structured task payload
    task_payload = build_task_payload(intent)
    script = build_script(intent.payload, task_payload)

    case Sprites.exec(sprite_name, script) do
      {:ok, %{output: output, exit_code: exit_code} = exec_result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_mono
        completed_at = DateTime.utc_now()

        broadcast_log(intent.id, output)

        if exit_code == 0 do
          artifacts = build_artifacts(output)
          register_artifact_links(intent, output)

          ExecutionResult.success(duration_ms, started_at, completed_at,
            output: exec_result,
            artifacts: artifacts,
            executor: __MODULE__
          )
        else
          ExecutionResult.failure(duration_ms, started_at, completed_at,
            error: {:nonzero_exit, exit_code},
            output: exec_result,
            executor: __MODULE__
          )
        end

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_mono
        completed_at = DateTime.utc_now()

        ExecutionResult.failure(duration_ms, started_at, completed_at,
          error: reason,
          executor: __MODULE__
        )
    end
  end

  # ── Script Building ────────────────────────────────────────────────

  @doc """
  Build the bash script to execute on the sprite from task payload fields.

  The script writes a structured task payload to `/workspace/.lattice/task.json`,
  clones the repo, creates a branch, applies the requested change,
  commits, pushes, and opens a PR. Returns the script as a string.

  User-supplied values (instructions, PR title, PR body) are written via
  heredocs or single-quoted strings to prevent shell injection.
  """
  @spec build_script(map(), TaskPayload.t()) :: String.t()
  def build_script(payload, %TaskPayload{} = task_payload) when is_map(payload) do
    repo = Map.fetch!(payload, "repo")
    task_kind = Map.fetch!(payload, "task_kind")
    instructions = Map.fetch!(payload, "instructions")
    base_branch = Map.get(payload, "base_branch", "main")
    pr_title = Map.get(payload, "pr_title", "Task: #{task_kind}")
    draft = Map.get(payload, "draft", false)
    issue_number = Map.get(payload, "issue_number")
    pr_body = build_pr_body(payload, task_kind, issue_number)
    branch_name = "lattice/#{task_kind}-#{:os.system_time(:second)}"

    # Use a unique heredoc delimiter to avoid collisions with user content
    heredoc_delim = "LATTICE_EOF_#{:erlang.phash2(instructions)}"

    {:ok, payload_json} = TaskPayload.serialize(task_payload)

    """
    set -euo pipefail
    cd /workspace

    # Write structured task payload
    mkdir -p .lattice
    cat > .lattice/task.json <<'LATTICE_PAYLOAD_EOF'
    #{payload_json}
    LATTICE_PAYLOAD_EOF

    # Clean up any previous run
    rm -rf task-repo

    git clone "https://github.com/#{repo}.git" task-repo
    cd task-repo
    git checkout -b '#{escape_single_quotes(branch_name)}' 'origin/#{escape_single_quotes(base_branch)}'

    # Task: #{sanitize_comment(task_kind)}
    cat > .lattice-task <<'#{heredoc_delim}'
    #{instructions}
    #{heredoc_delim}

    git add -A
    git commit -m '#{escape_single_quotes(pr_title)}'
    git push origin '#{escape_single_quotes(branch_name)}'

    PR_URL=$(gh pr create \
      --repo '#{escape_single_quotes(repo)}' \
      --title '#{escape_single_quotes(pr_title)}' \
      --body '#{escape_single_quotes(pr_body)}' \
      --base '#{escape_single_quotes(base_branch)}' \
      --head '#{escape_single_quotes(branch_name)}'#{if draft, do: " \\\n      --draft", else: ""} 2>&1 | grep -oE 'https://github\\.com/[^[:space:]]+/pull/[0-9]+' | head -1)

    if [ -z "${PR_URL}" ]; then
      echo "ERROR: gh pr create did not return a PR URL" >&2
      exit 1
    fi

    echo "LATTICE_PR_URL=${PR_URL}"
    echo '{"pr_url": "'"${PR_URL}"'"}'
    """
  end

  # ── PR URL Parsing ─────────────────────────────────────────────────

  @doc """
  Parse exec output for a GitHub PR URL.

  Returns the first PR URL found in the output, or `nil` if none is found.
  """
  @spec parse_pr_url(String.t()) :: String.t() | nil
  def parse_pr_url(output) when is_binary(output) do
    case Regex.run(@pr_url_pattern, output) do
      [url | _] -> url
      nil -> nil
    end
  end

  def parse_pr_url(_), do: nil

  # ── Task Payload ──────────────────────────────────────────────────

  defp build_task_payload(%Intent{} = intent) do
    payload = intent.payload

    {:ok, tp} =
      TaskPayload.new(%{
        run_id: intent.id,
        goal: Map.get(payload, "instructions", ""),
        repo: Map.get(payload, "repo"),
        skill: Map.get(payload, "task_kind"),
        constraints: %{
          base_branch: Map.get(payload, "base_branch", "main")
        },
        acceptance: Map.get(payload, "pr_title"),
        answers: %{},
        env: %{}
      })

    tp
  end

  # ── Private ────────────────────────────────────────────────────────

  defp build_pr_body(payload, task_kind, issue_number) do
    custom_body = Map.get(payload, "pr_body")

    if custom_body do
      maybe_append_issue_ref(custom_body, issue_number)
    else
      parts = ["Automated task: #{task_kind}"]

      parts =
        if issue_number do
          parts ++ ["", "Fixes ##{issue_number}"]
        else
          parts
        end

      (parts ++ ["", "_Created by Lattice_"]) |> Enum.join("\n")
    end
  end

  defp maybe_append_issue_ref(body, nil), do: body

  defp maybe_append_issue_ref(body, issue_number) do
    if String.contains?(body, "##{issue_number}") do
      body
    else
      body <> "\n\nPart of ##{issue_number}"
    end
  end

  defp register_artifact_links(%Intent{} = intent, output) do
    pr_url = parse_pr_url(output)
    issue_number = Map.get(intent.payload, "issue_number")

    if pr_url do
      # Extract PR number from URL
      pr_number =
        case Regex.run(~r{/pull/(\d+)}, pr_url) do
          [_, num] -> String.to_integer(num)
          _ -> nil
        end

      if pr_number do
        # Register PR artifact
        pr_link =
          ArtifactLink.new(%{
            intent_id: intent.id,
            kind: :pull_request,
            ref: pr_number,
            url: pr_url,
            role: :output
          })

        ArtifactRegistry.register(pr_link)

        # Register bidirectional issue link if applicable
        if issue_number do
          issue_link =
            ArtifactLink.new(%{
              intent_id: intent.id,
              kind: :issue,
              ref: issue_number,
              url: nil,
              role: :input
            })

          ArtifactRegistry.register(issue_link)
        end
      end
    end
  rescue
    error ->
      Logger.warning("Failed to register artifact links: #{inspect(error)}")
  end

  defp build_artifacts(output) when is_binary(output) do
    case parse_pr_url(output) do
      nil -> []
      url -> [%{type: "pr_url", data: url}]
    end
  end

  defp build_artifacts(_), do: []

  defp broadcast_log(intent_id, output) when is_binary(output) do
    lines = String.split(output, "\n", trim: true)

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "intents:#{intent_id}",
      {:intent_task_log, intent_id, lines}
    )
  rescue
    _error -> :ok
  end

  defp broadcast_log(_intent_id, _output), do: :ok

  @doc false
  def escape_single_quotes(str) when is_binary(str) do
    String.replace(str, "'", "'\\''")
  end

  defp sanitize_comment(str) when is_binary(str) do
    str
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.slice(0, 200)
  end
end
