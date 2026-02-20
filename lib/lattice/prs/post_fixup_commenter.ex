defmodule Lattice.PRs.PostFixupCommenter do
  @moduledoc """
  Subscribes to run completion events and posts summary comments on PRs
  after fixup runs complete.

  When a run for a `pr_fixup` intent completes, this module:
  1. Looks up the originating intent and its PR info
  2. Builds a structured GitHub comment with outcome, commit SHA, and details
  3. Posts the comment via `GitHub.create_comment/2`

  Runs as a GenServer in the supervision tree.
  """

  use GenServer

  require Logger

  alias Lattice.Capabilities.GitHub
  alias Lattice.Events
  alias Lattice.Intents.Store
  alias Lattice.PRs.Tracker

  # ── Public API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────

  @impl true
  def init(_opts) do
    Events.subscribe_runs()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:run_completed, run}, state) do
    handle_run_completed(run)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ──────────────────────────────────────────────────────

  defp handle_run_completed(%{intent_id: nil}), do: :ok

  defp handle_run_completed(%{intent_id: intent_id} = run) do
    with {:ok, intent} <- Store.get(intent_id),
         true <- intent.kind == :pr_fixup,
         {:ok, pr_number} <- extract_pr_number(intent) do
      post_fixup_comment(run, intent, pr_number, intent_id)
    else
      {:ok, _intent} -> :ok
      false -> :ok
      {:error, _} -> :ok
    end
  end

  defp post_fixup_comment(run, intent, pr_number, intent_id) do
    comment_body = build_comment(run, intent)

    case GitHub.create_comment(pr_number, comment_body) do
      {:ok, _} ->
        Logger.info("Posted fixup summary on PR ##{pr_number} for intent #{intent_id}")
        repo = extract_repo(intent)
        if repo, do: Tracker.update_pr(repo, pr_number, review_state: :pending)

      {:error, reason} ->
        Logger.warning("Failed to post fixup comment on PR ##{pr_number}: #{inspect(reason)}")
    end
  end

  defp extract_pr_number(%{payload: %{"pr_url" => url}}) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_, num_str] -> {:ok, String.to_integer(num_str)}
      _ -> {:error, :no_pr_number}
    end
  end

  defp extract_pr_number(_), do: {:error, :no_pr_url}

  defp extract_repo(%{payload: %{"pr_url" => url}}) do
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/}, url) do
      [_, repo] -> repo
      _ -> nil
    end
  end

  defp extract_repo(_), do: nil

  @doc false
  def build_comment(run, intent) do
    status_emoji = if run.status == :completed, do: "white_check_mark", else: "x"
    status_text = if run.status == :completed, do: "Success", else: "Failed"

    commit_sha = extract_commit_sha(run)
    feedback = intent.payload["feedback"] || "No feedback provided"

    parts = [
      "## :#{status_emoji}: Fixup #{status_text}",
      "",
      "**Intent:** `#{intent.id}`",
      "**Feedback addressed:**",
      "> #{feedback}"
    ]

    parts =
      if commit_sha do
        parts ++ ["", "**Commit:** `#{commit_sha}`"]
      else
        parts
      end

    parts =
      if run.status != :completed and run.error do
        parts ++ ["", "**Error:** `#{inspect(run.error)}`"]
      else
        parts
      end

    parts =
      parts ++
        [
          "",
          "<details>",
          "<summary>Run details</summary>",
          "",
          "- **Sprite:** #{run.sprite_name || "unknown"}",
          "- **Started:** #{run.started_at}",
          "- **Finished:** #{run.finished_at || "in progress"}",
          "",
          "</details>",
          "",
          "_Posted by Lattice_"
        ]

    Enum.join(parts, "\n")
  end

  defp extract_commit_sha(%{artifacts: artifacts}) when is_list(artifacts) do
    case Enum.find(artifacts, &match?(%{type: "commit"}, &1)) do
      %{data: sha} -> sha
      _ -> nil
    end
  end

  defp extract_commit_sha(_), do: nil
end
