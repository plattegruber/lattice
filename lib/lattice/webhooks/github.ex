defmodule Lattice.Webhooks.GitHub do
  @moduledoc """
  Handles GitHub webhook events and converts them into intent proposals.

  This module is the "Signal → Intent" bridge for GitHub events. It receives
  parsed webhook payloads, determines whether they should produce an intent,
  and proposes them through the pipeline.

  ## Supported Events

  - `issues.opened` with `lattice-work` label → `:action` intent
  - `issues.labeled` with `lattice-work` label → `:action` intent
  - `issue_comment.created` on governance issues → delegates to `Governance.sync_from_github/1`
  - `pull_request.review_submitted` with `changes_requested` → `:action` intent

  ## Design

  - Thin handler: parse, validate, propose
  - All governance logic stays in `Lattice.Intents.Governance`
  - Returns `{:ok, intent}` for proposed intents or `:ignored` for unhandled events
  """

  require Logger

  alias Lattice.Capabilities.GitHub.ArtifactLink
  alias Lattice.Capabilities.GitHub.ArtifactRegistry
  alias Lattice.Intents.Governance
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store

  @trigger_label "lattice-work"

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Handle a GitHub webhook event.

  Dispatches to the appropriate handler based on event type and action.
  Returns `{:ok, intent}` when an intent was proposed, `:ignored` when
  the event was not actionable, or `{:error, reason}` on failure.
  """
  @spec handle_event(String.t(), map()) :: {:ok, Intent.t()} | :ignored | {:error, term()}
  def handle_event(event_type, payload) do
    action = Map.get(payload, "action")
    do_handle(event_type, action, payload)
  end

  # ── Issues ──────────────────────────────────────────────────────────

  defp do_handle("issues", "opened", payload) do
    if has_trigger_label?(payload) do
      propose_issue_triage(payload)
    else
      :ignored
    end
  end

  defp do_handle("issues", "labeled", payload) do
    label = get_in(payload, ["label", "name"])

    if label == @trigger_label do
      propose_issue_triage(payload)
    else
      :ignored
    end
  end

  # ── Issue Comments (governance sync) ────────────────────────────────

  defp do_handle("issue_comment", "created", payload) do
    issue = Map.get(payload, "issue", %{})
    labels = get_label_names(issue)

    cond do
      "intent-awaiting-approval" in labels ->
        sync_governance_from_comment(issue)

      has_intent_id_in_body?(issue) ->
        sync_governance_from_comment(issue)

      true ->
        :ignored
    end
  end

  # ── Pull Request Reviews ────────────────────────────────────────────

  defp do_handle("pull_request", "review_submitted", payload) do
    review = Map.get(payload, "review", %{})
    state = Map.get(review, "state")

    if state == "changes_requested" do
      propose_pr_fixup(payload)
    else
      :ignored
    end
  end

  # ── Catch-all ───────────────────────────────────────────────────────

  defp do_handle(_event_type, _action, _payload), do: :ignored

  # ── Private: Intent Proposals ───────────────────────────────────────

  defp propose_issue_triage(payload) do
    issue = Map.get(payload, "issue", %{})
    repo = get_in(payload, ["repository", "full_name"]) || "unknown"
    issue_number = Map.get(issue, "number")
    issue_title = Map.get(issue, "title", "Untitled")
    issue_body = Map.get(issue, "body", "")
    sender = get_in(payload, ["sender", "login"]) || "unknown"

    source = %{type: :webhook, id: "github:issues:#{issue_number}"}

    case Intent.new_action(source,
           summary: "Triage issue ##{issue_number}: #{issue_title}",
           payload: %{
             "capability" => "github",
             "operation" => "issue_triage",
             "repo" => repo,
             "issue_number" => issue_number,
             "issue_title" => issue_title,
             "issue_body" => issue_body,
             "sender" => sender
           },
           affected_resources: ["repo:#{repo}", "issue:#{issue_number}"],
           expected_side_effects: ["triage issue ##{issue_number}"],
           metadata: %{webhook_event: "issues", webhook_sender: sender}
         ) do
      {:ok, intent} ->
        case Pipeline.propose(intent) do
          {:ok, proposed} = result ->
            issue_url = get_in(payload, ["issue", "html_url"])
            register_input_artifact(proposed.id, :issue, issue_number, issue_url)
            result

          error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp propose_pr_fixup(payload) do
    pr = Map.get(payload, "pull_request", %{})
    review = Map.get(payload, "review", %{})
    repo = get_in(payload, ["repository", "full_name"]) || "unknown"
    pr_number = Map.get(pr, "number")
    pr_title = Map.get(pr, "title", "Untitled")
    review_body = Map.get(review, "body", "")
    reviewer = Map.get(review, "user", %{}) |> Map.get("login", "unknown")

    source = %{type: :webhook, id: "github:pull_request:#{pr_number}:review"}

    case Intent.new_action(source,
           summary: "Fix PR ##{pr_number}: #{pr_title} (changes requested by #{reviewer})",
           payload: %{
             "capability" => "github",
             "operation" => "pr_fixup",
             "repo" => repo,
             "pr_number" => pr_number,
             "pr_title" => pr_title,
             "review_body" => review_body,
             "reviewer" => reviewer
           },
           affected_resources: ["repo:#{repo}", "pr:#{pr_number}"],
           expected_side_effects: ["address review on PR ##{pr_number}"],
           metadata: %{webhook_event: "pull_request", webhook_sender: reviewer}
         ) do
      {:ok, intent} ->
        case Pipeline.propose(intent) do
          {:ok, proposed} = result ->
            pr_url = get_in(payload, ["pull_request", "html_url"])
            register_input_artifact(proposed.id, :pull_request, pr_number, pr_url)
            result

          error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  # ── Private: Governance Sync ────────────────────────────────────────

  defp sync_governance_from_comment(issue) do
    body = Map.get(issue, "body", "")

    with {:ok, intent_id} <- extract_intent_id(body),
         {:ok, intent} <- fetch_intent_for_sync(intent_id) do
      case Governance.sync_from_github(intent) do
        {:ok, %Intent{}} = result -> result
        {:ok, :no_change} -> :ignored
        {:error, _} = error -> error
      end
    else
      _ -> :ignored
    end
  end

  defp fetch_intent_for_sync(intent_id) do
    case Store.get(intent_id) do
      {:ok, _intent} = result ->
        result

      {:error, :not_found} ->
        Logger.debug("Webhook: governance comment for unknown intent #{intent_id}")
        :error
    end
  end

  # ── Private: Helpers ────────────────────────────────────────────────

  defp has_trigger_label?(payload) do
    issue = Map.get(payload, "issue", %{})
    labels = get_label_names(issue)
    @trigger_label in labels
  end

  defp get_label_names(issue) do
    issue
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
  end

  defp has_intent_id_in_body?(issue) do
    body = Map.get(issue, "body", "")
    String.contains?(body, "lattice:intent_id=")
  end

  @intent_id_regex ~r/lattice:intent_id=([a-zA-Z0-9_-]+)/

  defp extract_intent_id(body) when is_binary(body) do
    case Regex.run(@intent_id_regex, body) do
      [_, intent_id] -> {:ok, intent_id}
      _ -> :error
    end
  end

  defp register_input_artifact(intent_id, kind, ref, url) do
    link =
      ArtifactLink.new(%{
        intent_id: intent_id,
        kind: kind,
        ref: ref,
        url: url,
        role: :input
      })

    ArtifactRegistry.register(link)
  rescue
    _ -> :ok
  end
end
