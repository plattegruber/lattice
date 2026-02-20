defmodule Lattice.Capabilities.GitHub.AssignmentPolicy do
  @moduledoc """
  Config-driven assignment policy for GitHub governance issues and PR reviews.

  Determines who gets assigned governance issues and who gets requested
  for PR reviews based on intent classification and configuration.

  ## Configuration

      config :lattice, :github_assignments,
        default_reviewer: "operator-username",
        dangerous_reviewer: "senior-operator",
        assign_governance_issues: true,
        request_pr_reviews: true

  If no configuration is set, assignment is disabled (no-op).
  """

  require Logger

  alias Lattice.Capabilities.GitHub

  @doc """
  Returns the reviewer username(s) for a given classification level.

  For `:dangerous` intents, returns the `dangerous_reviewer` if configured,
  otherwise falls back to `default_reviewer`.

  Returns `nil` if no reviewer is configured.
  """
  @spec reviewer_for_classification(atom()) :: String.t() | nil
  def reviewer_for_classification(classification) do
    config = config()

    case classification do
      :dangerous ->
        Keyword.get(config, :dangerous_reviewer) || Keyword.get(config, :default_reviewer)

      _ ->
        Keyword.get(config, :default_reviewer)
    end
  end

  @doc """
  Auto-assign a governance issue based on the intent's classification.

  Only assigns if `assign_governance_issues: true` is configured and a
  reviewer is found for the classification level.

  Returns `:ok` (fire-and-forget; assignment failure is logged but not fatal).
  """
  @spec auto_assign_governance(pos_integer(), atom()) :: :ok
  def auto_assign_governance(issue_number, classification) do
    with true <- assign_governance_issues?(),
         reviewer when not is_nil(reviewer) <- reviewer_for_classification(classification) do
      case GitHub.assign_issue(issue_number, [reviewer]) do
        {:ok, _} ->
          :telemetry.execute(
            [:lattice, :github, :assigned],
            %{count: 1},
            %{issue_number: issue_number, reviewer: reviewer, classification: classification}
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to assign issue ##{issue_number} to #{reviewer}: #{inspect(reason)}"
          )

          :ok
      end
    else
      nil ->
        Logger.debug("No reviewer configured for classification #{classification}")
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Auto-request PR review based on configuration.

  Only requests review if `request_pr_reviews: true` is configured and a
  reviewer is found.

  Returns `:ok` (fire-and-forget).
  """
  @spec auto_request_review(pos_integer()) :: :ok
  def auto_request_review(pr_number) do
    with true <- request_pr_reviews?(),
         reviewer when not is_nil(reviewer) <- Keyword.get(config(), :default_reviewer) do
      case GitHub.request_review(pr_number, [reviewer]) do
        :ok ->
          :telemetry.execute(
            [:lattice, :github, :review_requested],
            %{count: 1},
            %{pr_number: pr_number, reviewer: reviewer}
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to request review on PR ##{pr_number} from #{reviewer}: #{inspect(reason)}"
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  @doc "Whether governance issue assignment is enabled."
  @spec assign_governance_issues?() :: boolean()
  def assign_governance_issues? do
    Keyword.get(config(), :assign_governance_issues, false)
  end

  @doc "Whether PR review requests are enabled."
  @spec request_pr_reviews?() :: boolean()
  def request_pr_reviews? do
    Keyword.get(config(), :request_pr_reviews, false)
  end

  defp config do
    Application.get_env(:lattice, :github_assignments, [])
  end
end
