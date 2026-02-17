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

  alias Lattice.Capabilities.Sprites
  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Intent

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
    script = build_script(intent.payload)

    case Sprites.exec(sprite_name, script) do
      {:ok, %{output: output, exit_code: exit_code} = exec_result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_mono
        completed_at = DateTime.utc_now()

        broadcast_log(intent.id, output)

        if exit_code == 0 do
          artifacts = build_artifacts(output)

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

  The script clones the repo, creates a branch, applies the requested change,
  commits, pushes, and opens a PR. Returns the script as a string.
  """
  @spec build_script(map()) :: String.t()
  def build_script(payload) when is_map(payload) do
    repo = Map.fetch!(payload, "repo")
    task_kind = Map.fetch!(payload, "task_kind")
    instructions = Map.fetch!(payload, "instructions")
    base_branch = Map.get(payload, "base_branch", "main")
    pr_title = Map.get(payload, "pr_title", "Task: #{task_kind}")
    pr_body = Map.get(payload, "pr_body", "Automated task: #{task_kind}")
    branch_name = "lattice/#{task_kind}-#{:os.system_time(:second)}"

    """
    set -euo pipefail
    cd /workspace
    git clone "https://github.com/#{repo}.git" task-repo
    cd task-repo
    git checkout -b "#{branch_name}" "origin/#{base_branch}"

    # Task: #{task_kind}
    # Instructions: #{instructions}
    echo "#{instructions}" > .lattice-task

    git add -A
    git commit -m "#{escape_shell(pr_title)}"
    git push origin "#{branch_name}"

    PR_URL=$(gh pr create \
      --title "#{escape_shell(pr_title)}" \
      --body "#{escape_shell(pr_body)}" \
      --base "#{base_branch}" \
      --head "#{branch_name}" 2>&1 | tail -1)

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

  # ── Private ────────────────────────────────────────────────────────

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

  defp escape_shell(str) when is_binary(str) do
    String.replace(str, ~s("), ~s(\\"))
  end
end
