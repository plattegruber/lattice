defmodule Lattice.Intents.Governance do
  @moduledoc """
  Bridges the intent pipeline with GitHub Issues for human-in-the-loop governance.

  When an intent requires approval (`:awaiting_approval`), this module creates a
  structured GitHub issue with all relevant details. Humans review the issue and
  apply labels to approve or reject. The sync flow reads those labels and drives
  intent state transitions.

  ## Flow

  1. Intent enters `:awaiting_approval` via Pipeline
  2. `create_governance_issue/1` creates a GitHub issue with structured body
  3. Human reviews and applies `intent-approved` or `intent-rejected` label
  4. `sync_from_github/1` reads labels and calls Pipeline.approve/reject
  5. After execution, `post_outcome/2` posts results as a comment
  6. On terminal state, `close_governance_issue/1` closes the issue

  ## Labels

  See `Lattice.Intents.Governance.Labels` for the label definitions.

  ## GitHub Capability

  All GitHub interactions go through the `Lattice.Capabilities.GitHub` behaviour,
  so this works with the stub in dev and the live implementation in prod.
  """

  alias Lattice.Capabilities.GitHub
  alias Lattice.Intents.Governance.Labels, as: GovLabels
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store
  alias Lattice.Safety.Audit

  # ── Public API ────────────────────────────────────────────────────

  @doc """
  Create a GitHub governance issue for an intent awaiting approval.

  The issue includes structured sections for the intent kind, summary,
  classification, payload, affected resources, expected side effects,
  and rollback strategy. The issue is labeled with `intent-awaiting-approval`.

  The governance issue number is stored in the intent's metadata under
  the key `:governance_issue`.

  Returns `{:ok, intent}` with updated metadata, or `{:error, reason}`.
  """
  @spec create_governance_issue(Intent.t()) :: {:ok, Intent.t()} | {:error, term()}
  def create_governance_issue(%Intent{state: :awaiting_approval} = intent) do
    title = governance_issue_title(intent)
    body = format_issue_body(intent)

    attrs = %{
      body: body,
      labels: [GovLabels.awaiting_approval()]
    }

    case GitHub.create_issue(title, attrs) do
      {:ok, issue} ->
        metadata = Map.put(intent.metadata, :governance_issue, issue.number)

        case Store.update(intent.id, %{metadata: metadata}) do
          {:ok, updated} ->
            Audit.log(:governance, :create_issue, :controlled, :ok, :system,
              args: [intent.id, issue.number]
            )

            {:ok, updated}

          {:error, _} = error ->
            error
        end

      {:error, reason} = error ->
        Audit.log(:governance, :create_issue, :controlled, error, :system, args: [intent.id])

        {:error, reason}
    end
  end

  def create_governance_issue(%Intent{state: state}) do
    {:error, {:wrong_state, state}}
  end

  @doc """
  Sync an intent's state from its governance GitHub issue.

  Reads the governance issue's labels and transitions the intent if a human
  has applied `intent-approved` or `intent-rejected`.

  Returns `{:ok, intent}` with the updated state, `{:ok, :no_change}` if
  no actionable label was found, or `{:error, reason}`.
  """
  @spec sync_from_github(Intent.t()) :: {:ok, Intent.t() | :no_change} | {:error, term()}
  def sync_from_github(%Intent{state: :awaiting_approval, metadata: metadata} = intent) do
    case Map.fetch(metadata, :governance_issue) do
      {:ok, issue_number} ->
        check_and_transition(intent, issue_number)

      :error ->
        {:error, :no_governance_issue}
    end
  end

  def sync_from_github(%Intent{state: state}) do
    {:error, {:wrong_state, state}}
  end

  @doc """
  Post an execution outcome as a comment on the governance issue.

  Formats the result into a structured comment and posts it to the
  GitHub issue linked to the intent.

  Returns `{:ok, comment}` or `{:error, reason}`.
  """
  @spec post_outcome(Intent.t(), map()) :: {:ok, map()} | {:error, term()}
  def post_outcome(%Intent{metadata: metadata} = intent, result) do
    case Map.fetch(metadata, :governance_issue) do
      {:ok, issue_number} ->
        body = format_outcome_comment(intent, result)

        case GitHub.create_comment(issue_number, body) do
          {:ok, comment} ->
            Audit.log(:governance, :post_outcome, :safe, :ok, :system,
              args: [intent.id, issue_number]
            )

            {:ok, comment}

          {:error, _} = error ->
            error
        end

      :error ->
        {:error, :no_governance_issue}
    end
  end

  @doc """
  Close the governance issue when the intent reaches a terminal state.

  Updates the issue state to closed and applies the appropriate terminal
  label if the intent was approved or rejected.

  Returns `{:ok, issue}` or `{:error, reason}`.
  """
  @spec close_governance_issue(Intent.t()) :: {:ok, map()} | {:error, term()}
  def close_governance_issue(%Intent{state: state, metadata: metadata} = intent)
      when state in [:completed, :failed, :rejected, :canceled] do
    case Map.fetch(metadata, :governance_issue) do
      {:ok, issue_number} ->
        # Add terminal state label if applicable
        case GovLabels.for_state(state) do
          {:ok, label} -> GitHub.add_label(issue_number, label)
          {:error, :no_label} -> :ok
        end

        case GitHub.update_issue(issue_number, %{state: "closed"}) do
          {:ok, issue} ->
            Audit.log(:governance, :close_issue, :controlled, :ok, :system,
              args: [intent.id, issue_number]
            )

            {:ok, issue}

          {:error, _} = error ->
            error
        end

      :error ->
        {:error, :no_governance_issue}
    end
  end

  def close_governance_issue(%Intent{state: state}) do
    {:error, {:not_terminal, state}}
  end

  @doc """
  Format the GitHub issue body for a governance issue.

  Includes structured sections for intent kind, summary, classification,
  payload, affected resources, expected side effects, and rollback strategy.
  Inquiry intents include additional fields: what is requested, why it is
  needed, scope of impact, and expiration.
  """
  @spec format_issue_body(Intent.t()) :: String.t()
  def format_issue_body(%Intent{} = intent) do
    sections = [
      intent_header(intent),
      classification_section(intent),
      payload_section(intent),
      resources_section(intent),
      side_effects_section(intent),
      rollback_section(intent),
      inquiry_section(intent),
      plan_section(intent),
      source_section(intent),
      approval_instructions(intent),
      traceability_footer(intent)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # ── Private: GitHub Sync ──────────────────────────────────────────

  defp check_and_transition(intent, issue_number) do
    case GitHub.get_issue(issue_number) do
      {:ok, issue} ->
        labels = Map.get(issue, :labels, [])
        resolve_label_action(intent, labels, issue)

      {:error, _} = error ->
        error
    end
  end

  defp resolve_label_action(intent, labels, issue) do
    cond do
      GovLabels.approved() in labels ->
        comments = extract_comments(issue)

        case Pipeline.approve(intent.id,
               actor: :github,
               reason: "approved via GitHub issue ##{intent.metadata[:governance_issue]}"
             ) do
          {:ok, approved} ->
            store_comments_as_metadata(approved, comments)

          {:error, _} = error ->
            error
        end

      GovLabels.rejected() in labels ->
        comments = extract_comments(issue)

        case Pipeline.reject(intent.id,
               actor: :github,
               reason: "rejected via GitHub issue ##{intent.metadata[:governance_issue]}"
             ) do
          {:ok, rejected} ->
            store_comments_as_metadata(rejected, comments)

          {:error, _} = error ->
            error
        end

      true ->
        {:ok, :no_change}
    end
  end

  defp extract_comments(%{comments: comments}) when is_list(comments) do
    Enum.map(comments, fn comment ->
      %{body: Map.get(comment, :body, "")}
    end)
  end

  defp extract_comments(_), do: []

  defp store_comments_as_metadata(intent, []), do: {:ok, intent}

  defp store_comments_as_metadata(intent, comments) do
    metadata = Map.put(intent.metadata, :github_comments, comments)
    Store.update(intent.id, %{metadata: metadata})
  end

  # ── Private: Issue Formatting ────────────────────────────────────

  defp governance_issue_title(%Intent{kind: kind, summary: summary}) do
    kind_label = kind |> to_string() |> String.capitalize()
    "[Intent/#{kind_label}] #{summary}"
  end

  defp intent_header(%Intent{kind: kind, summary: summary}) do
    """
    ## Intent Summary

    **Kind:** #{kind}
    **Summary:** #{summary}\
    """
  end

  defp classification_section(%Intent{classification: nil}), do: nil

  defp classification_section(%Intent{classification: classification}) do
    emoji =
      case classification do
        :safe -> "green"
        :controlled -> "yellow"
        :dangerous -> "red"
      end

    """
    ## Classification

    **Level:** #{classification} (#{emoji})\
    """
  end

  defp payload_section(%Intent{payload: payload}) when map_size(payload) == 0, do: nil

  defp payload_section(%Intent{payload: payload}) do
    formatted =
      payload
      |> Enum.map_join("\n", fn {key, value} -> "- **#{key}:** #{inspect(value)}" end)

    """
    ## Payload

    #{formatted}\
    """
  end

  defp resources_section(%Intent{affected_resources: []}), do: nil

  defp resources_section(%Intent{affected_resources: resources}) do
    formatted = Enum.map_join(resources, "\n", fn r -> "- #{r}" end)

    """
    ## Affected Resources

    #{formatted}\
    """
  end

  defp side_effects_section(%Intent{expected_side_effects: []}), do: nil

  defp side_effects_section(%Intent{expected_side_effects: effects}) do
    formatted = Enum.map_join(effects, "\n", fn e -> "- #{e}" end)

    """
    ## Expected Side Effects

    #{formatted}\
    """
  end

  defp rollback_section(%Intent{rollback_strategy: nil}), do: nil

  defp rollback_section(%Intent{rollback_strategy: strategy}) do
    """
    ## Rollback Strategy

    #{strategy}\
    """
  end

  defp inquiry_section(%Intent{kind: :inquiry, payload: payload}) do
    what = Map.get(payload, "what_requested", "N/A")
    why = Map.get(payload, "why_needed", "N/A")
    scope = Map.get(payload, "scope_of_impact", "N/A")
    expiration = Map.get(payload, "expiration", "N/A")

    """
    ## Inquiry Details

    **What is requested:** #{what}
    **Why it is needed:** #{why}
    **Scope of impact:** #{scope}
    **Expiration:** #{expiration}\
    """
  end

  defp inquiry_section(_intent), do: nil

  defp plan_section(%Intent{plan: nil}), do: nil

  defp plan_section(%Intent{plan: plan}) do
    """
    ## Execution Plan

    #{plan.rendered_markdown}\
    """
  end

  defp source_section(%Intent{source: source}) do
    """
    ## Source

    **Type:** #{source.type}
    **ID:** `#{source.id}`\
    """
  end

  defp approval_instructions(%Intent{}) do
    """
    ## Approval

    To approve this intent, add the `#{GovLabels.approved()}` label.
    To reject this intent, add the `#{GovLabels.rejected()}` label.

    ---
    _Created by Lattice governance. Do not modify the intent payload directly._\
    """
  end

  defp traceability_footer(%Intent{id: id}) do
    """
    <!-- lattice:intent_id=#{id} -->\
    """
  end

  @doc """
  Post a comment on the original intent's governance issue linking to the
  rollback intent. Called when a rollback intent is proposed.

  Returns `{:ok, comment}` or `{:error, reason}`.
  """
  @spec post_rollback_link(Intent.t(), Intent.t()) :: {:ok, map()} | {:error, term()}
  def post_rollback_link(%Intent{metadata: metadata} = _original, %Intent{} = rollback) do
    case Map.fetch(metadata, :governance_issue) do
      {:ok, issue_number} ->
        body = """
        ## Rollback Proposed

        A rollback intent has been created: `#{rollback.id}`

        **Summary:** #{rollback.summary}
        **Classification:** #{rollback.classification || "pending"}

        ---
        _Posted by Lattice governance._
        """

        GitHub.create_comment(issue_number, body)

      :error ->
        {:error, :no_governance_issue}
    end
  end

  # ── Private: Outcome Formatting ──────────────────────────────────

  defp format_outcome_comment(%Intent{} = intent, result) do
    status = Map.get(result, :status, :unknown)
    output = Map.get(result, :output)
    error = Map.get(result, :error)
    duration_ms = Map.get(result, :duration_ms)

    status_emoji =
      case status do
        :success -> "Completed"
        :failure -> "Failed"
        _ -> "Unknown"
      end

    sections = [
      "## Execution Outcome: #{status_emoji}",
      "**Intent:** #{intent.id}",
      if(duration_ms, do: "**Duration:** #{duration_ms}ms"),
      if(output, do: "**Output:** #{inspect(output)}"),
      if(error, do: "**Error:** #{inspect(error)}"),
      "\n---\n_Posted by Lattice governance._"
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
