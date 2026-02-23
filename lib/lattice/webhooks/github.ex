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
  alias Lattice.Events
  alias Lattice.Intents.Governance
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store
  alias Lattice.Runs
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite

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
    maybe_broadcast_ambient(:issue_opened, payload)

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

  # ── Issue Comments (governance sync + ambient) ──────────────────────

  defp do_handle("issue_comment", "created", payload) do
    issue = Map.get(payload, "issue", %{})
    labels = get_label_names(issue)
    issue_number = Map.get(issue, "number")

    # Always broadcast ambient event for non-bot comments
    maybe_broadcast_ambient(:issue_comment, payload)

    cond do
      "intent-awaiting-approval" in labels ->
        sync_governance_from_comment(issue)

      has_intent_id_in_body?(issue) ->
        sync_governance_from_comment(issue)

      true ->
        # Route to an existing Sprite if one is managing this issue
        route_to_existing_sprite(:issue, issue_number, :issue_comment, payload)
    end
  end

  # ── Pull Request Reviews (ambient + existing) ──────────────────────

  defp do_handle("pull_request", "review_submitted", payload) do
    review = Map.get(payload, "review", %{})
    state = Map.get(review, "state")

    if state == "changes_requested" do
      propose_pr_fixup(payload)
    else
      :ignored
    end
  end

  # ── PR Synchronize (code push to PR branch) ────────────────────────

  defp do_handle("pull_request", "synchronize", payload) do
    pr = Map.get(payload, "pull_request", %{})
    pr_number = Map.get(pr, "number")
    maybe_broadcast_ambient(:pr_review, payload)
    route_to_existing_sprite(:pull_request, pr_number, :pr_synchronize, payload)
  end

  # ── Push to branch ─────────────────────────────────────────────────

  defp do_handle("push", _action, payload) do
    ref = Map.get(payload, "ref", "")

    # Extract branch name from "refs/heads/<branch>"
    case Regex.run(~r|^refs/heads/(.+)$|, ref) do
      [_, branch] ->
        route_to_existing_sprite(:branch, branch, :push, payload)

      _ ->
        :ignored
    end
  end

  # ── PR Reviews (ambient) ───────────────────────────────────────────

  defp do_handle("pull_request_review", "submitted", payload) do
    maybe_broadcast_ambient(:pr_review, payload)
    :ignored
  end

  # ── PR Review Comments (ambient) ───────────────────────────────────

  defp do_handle("pull_request_review_comment", "created", payload) do
    maybe_broadcast_ambient(:pr_review_comment, payload)
    :ignored
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

  # ── Private: Ambient Broadcasting ──────────────────────────────

  defp maybe_broadcast_ambient(type, payload) do
    sender = get_in(payload, ["sender", "login"]) || "unknown"
    body = extract_body(type, payload)

    # Skip bot users, configured bot login, and Lattice's own comments
    if skip_ambient?(sender, body) do
      :ok
    else
      event = build_ambient_event(type, payload, sender)
      Events.broadcast_ambient_event(event)
    end
  end

  defp skip_ambient?(sender, body) do
    bot_user?(sender) or lattice_user?(sender) or lattice_comment?(body)
  end

  defp bot_user?(login) do
    String.ends_with?(login, "[bot]") or login == "github-actions"
  end

  defp lattice_user?(login) do
    configured_login = responder_bot_login()
    not is_nil(configured_login) and login == configured_login
  end

  defp lattice_comment?(body) when is_binary(body) do
    # Lattice comments contain sentinel markers like <!-- lattice:... -->
    String.contains?(body, "<!-- lattice:")
  end

  defp lattice_comment?(_), do: false

  defp extract_body(:issue_opened, payload),
    do: get_in(payload, ["issue", "body"]) || ""

  defp extract_body(:issue_comment, payload),
    do: get_in(payload, ["comment", "body"]) || ""

  defp extract_body(:pr_review, payload),
    do: get_in(payload, ["review", "body"]) || ""

  defp extract_body(:pr_review_comment, payload),
    do: get_in(payload, ["comment", "body"]) || ""

  defp responder_bot_login do
    Application.get_env(:lattice, Lattice.Ambient.Responder, [])
    |> Keyword.get(:bot_login)
  end

  defp build_ambient_event(:issue_opened, payload, sender) do
    issue = Map.get(payload, "issue", %{})

    %{
      type: :issue_opened,
      surface: :issue,
      number: Map.get(issue, "number"),
      body: Map.get(issue, "body", ""),
      title: Map.get(issue, "title", ""),
      author: sender,
      comment_id: nil,
      repo: get_in(payload, ["repository", "full_name"]) || "unknown"
    }
  end

  defp build_ambient_event(:issue_comment, payload, sender) do
    comment = Map.get(payload, "comment", %{})
    issue = Map.get(payload, "issue", %{})

    %{
      type: :issue_comment,
      surface: :issue,
      number: Map.get(issue, "number"),
      body: Map.get(comment, "body", ""),
      title: Map.get(issue, "title", ""),
      context_body: Map.get(issue, "body", ""),
      context_author: get_in(issue, ["user", "login"]) || "unknown",
      author: sender,
      comment_id: Map.get(comment, "id"),
      repo: get_in(payload, ["repository", "full_name"]) || "unknown"
    }
  end

  defp build_ambient_event(:pr_review, payload, sender) do
    review = Map.get(payload, "review", %{})
    pr = Map.get(payload, "pull_request", %{})

    %{
      type: :pr_review,
      surface: :pr_review,
      number: Map.get(pr, "number"),
      body: Map.get(review, "body", ""),
      title: Map.get(pr, "title", ""),
      context_body: Map.get(pr, "body", ""),
      context_author: get_in(pr, ["user", "login"]) || "unknown",
      author: sender,
      comment_id: Map.get(review, "id"),
      repo: get_in(payload, ["repository", "full_name"]) || "unknown"
    }
  end

  defp build_ambient_event(:pr_review_comment, payload, sender) do
    comment = Map.get(payload, "comment", %{})
    pr = Map.get(payload, "pull_request", %{})

    %{
      type: :pr_review_comment,
      surface: :pr_review_comment,
      number: Map.get(pr, "number"),
      body: Map.get(comment, "body", ""),
      title: Map.get(pr, "title", ""),
      context_body: Map.get(pr, "body", ""),
      context_author: get_in(pr, ["user", "login"]) || "unknown",
      author: sender,
      comment_id: Map.get(comment, "id"),
      repo: get_in(payload, ["repository", "full_name"]) || "unknown"
    }
  end

  # ── Private: Routing to Existing Sprites ────────────────────────────

  # Attempt to route a GitHub update event to the Sprite GenServer that is
  # currently managing work for the given GitHub reference (issue number, PR
  # number, or branch name). Falls back to :ignored when no active run is
  # found so the caller can decide what to do next.
  defp route_to_existing_sprite(kind, ref, event_kind, payload) do
    with [_ | _] = links <- ArtifactRegistry.lookup_by_ref(kind, ref),
         {:ok, sprite_name} <- find_active_sprite_for_links(links),
         {:ok, pid} <- FleetManager.get_sprite_pid(sprite_name) do
      Logger.debug(
        "Routing GitHub #{event_kind} for #{kind}:#{ref} to sprite #{sprite_name}",
        kind: kind,
        ref: ref,
        sprite_name: sprite_name,
        event_kind: event_kind
      )

      Sprite.route_github_update(pid, event_kind, payload)
      :ok
    else
      _ -> :ignored
    end
  end

  # Find a sprite name associated with any active run for the given artifact links.
  defp find_active_sprite_for_links(links) do
    active_statuses = [:pending, :running, :blocked, :blocked_waiting_for_user, :waiting]

    result =
      Enum.find_value(links, fn %ArtifactLink{intent_id: intent_id} ->
        {:ok, runs} = Runs.Store.list_by_intent(intent_id)

        active_run =
          Enum.find(runs, fn run -> run.status in active_statuses end)

        if active_run, do: active_run.sprite_name
      end)

    if result, do: {:ok, result}, else: :error
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
