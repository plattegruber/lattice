defmodule Lattice.Capabilities.GitHub.WorkProposal do
  @moduledoc """
  Orchestrates the work proposal flow for the GitHub human-in-the-loop workflow.

  When a Sprite wants to perform a non-trivial action, Lattice creates a GitHub
  issue with the `proposed` label and a structured body describing the intent.
  Humans review and apply the `approved` label to grant permission.

  ## Safety Rules

  - Lattice NEVER merges PRs autonomously
  - Lattice only acts after `approved` label is present
  - All proposals are logged via telemetry and audit

  ## Flow

  1. `propose_work/2` creates an issue with the `proposed` label
  2. Humans review the issue, discuss in comments, and add `approved`
  3. `check_approval/1` polls the issue to see if `approved` label is present
  4. Once approved, the caller can transition to `in-progress` and execute
  """

  alias Lattice.Capabilities.GitHub
  alias Lattice.Capabilities.GitHub.Labels
  alias Lattice.Safety.Audit

  @doc """
  Propose work by creating a GitHub issue with the `proposed` label.

  The proposal includes the action description, the sprite that will execute it,
  and any relevant context.

  ## Parameters

  - `action` -- a short description of the proposed action (used as issue title)
  - `opts` -- keyword list with:
    - `:sprite_id` (required) -- the Sprite that will execute the action
    - `:reason` -- why this action is needed
    - `:context` -- additional context map (current state, etc.)

  ## Examples

      WorkProposal.propose_work("Deploy new version to staging", [
        sprite_id: "sprite-001",
        reason: "New feature branch is ready for testing",
        context: %{branch: "feature/new-ui", current_version: "1.2.3"}
      ])

  """
  @spec propose_work(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def propose_work(action, opts) when is_binary(action) and is_list(opts) do
    sprite_id = Keyword.fetch!(opts, :sprite_id)
    reason = Keyword.get(opts, :reason, "No reason provided")
    context = Keyword.get(opts, :context, %{})

    body = format_proposal_body(action, sprite_id, reason, context)

    attrs = %{
      body: body,
      labels: [Labels.initial()]
    }

    case GitHub.create_issue("[Sprite] #{action}", attrs) do
      {:ok, issue} ->
        Audit.log(:github, :propose_work, :controlled, :ok, :system, args: [action, sprite_id])

        {:ok, issue}

      {:error, reason} = error ->
        Audit.log(:github, :propose_work, :controlled, error, :system, args: [action, sprite_id])

        {:error, reason}
    end
  end

  @doc """
  Check whether a proposed issue has been approved.

  Fetches the issue and checks if the `approved` label is present.

  Returns `{:ok, :approved}` if approved, `{:ok, :pending}` if still
  waiting, or `{:error, reason}` on failure.

  ## Examples

      WorkProposal.check_approval(42)
      #=> {:ok, :approved}

      WorkProposal.check_approval(42)
      #=> {:ok, :pending}

  """
  @spec check_approval(pos_integer()) :: {:ok, :approved | :pending} | {:error, term()}
  def check_approval(issue_number) when is_integer(issue_number) do
    case GitHub.get_issue(issue_number) do
      {:ok, issue} ->
        if "approved" in Map.get(issue, :labels, []) do
          {:ok, :approved}
        else
          {:ok, :pending}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Transition an issue's HITL label, validating the state machine.

  Removes the `from` label and adds the `to` label, but only if the
  transition is valid according to `Labels.validate_transition/2`.

  ## Examples

      WorkProposal.transition_label(42, "approved", "in-progress")
      #=> {:ok, ["in-progress"]}

      WorkProposal.transition_label(42, "proposed", "done")
      #=> {:error, {:invalid_transition, "proposed", "done"}}

  """
  @spec transition_label(pos_integer(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def transition_label(issue_number, from, to) do
    case Labels.validate_transition(from, to) do
      :ok ->
        with {:ok, _} <- GitHub.remove_label(issue_number, from) do
          GitHub.add_label(issue_number, to)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Mark a proposal as complete by transitioning to `done`.

  Also adds a completion comment to the issue.

  ## Examples

      WorkProposal.complete(42, "in-progress", "Deployment successful")

  """
  @spec complete(pos_integer(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def complete(issue_number, current_label, summary) do
    case transition_label(issue_number, current_label, "done") do
      {:ok, labels} ->
        GitHub.create_comment(
          issue_number,
          "## Completed\n\n#{summary}\n\n_Marked done by Lattice._"
        )

        {:ok, labels}

      {:error, _} = error ->
        error
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp format_proposal_body(action, sprite_id, reason, context) do
    context_section =
      if context == %{} do
        ""
      else
        context_lines =
          Enum.map_join(context, "\n", fn {key, value} -> "- **#{key}:** #{value}" end)

        "\n## Context\n\n#{context_lines}\n"
      end

    """
    ## Proposed Action

    **Action:** #{action}
    **Sprite:** `#{sprite_id}`
    **Reason:** #{reason}
    #{context_section}
    ## Approval

    Add the `approved` label to authorize this action.

    ---
    _Created by Lattice. Do not merge PRs from this issue automatically._
    """
  end
end
