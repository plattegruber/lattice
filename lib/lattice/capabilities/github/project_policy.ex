defmodule Lattice.Capabilities.GitHub.ProjectPolicy do
  @moduledoc """
  Config-driven policy for GitHub Projects v2 integration.

  When configured with a `default_project_id`, this module automatically adds
  governance issues and output PRs to the project and updates status fields
  as intents transition through lifecycle states.

  ## Configuration

      config :lattice, :github_projects,
        default_project_id: "PVT_...",
        auto_add_governance_issues: true,
        auto_add_output_prs: true,
        status_field: "Status",
        status_mapping: %{
          awaiting_approval: "In Review",
          running: "In Progress",
          completed: "Done",
          failed: "Done"
        }

  If `default_project_id` is nil or not set, all operations are no-ops.
  """

  require Logger

  alias Lattice.Capabilities.GitHub

  @doc """
  Auto-add a governance issue to the configured project.

  Only operates if `default_project_id` is configured and
  `auto_add_governance_issues` is true.

  Returns `:ok` (fire-and-forget).
  """
  @spec auto_add_governance_issue(String.t()) :: :ok
  def auto_add_governance_issue(issue_node_id) do
    with true <- auto_add_governance_issues?(),
         project_id when not is_nil(project_id) <- default_project_id() do
      case GitHub.add_to_project(project_id, issue_node_id) do
        {:ok, result} ->
          :telemetry.execute(
            [:lattice, :github, :project_item_added],
            %{count: 1},
            %{project_id: project_id, content_type: :issue}
          )

          Logger.debug("Added governance issue to project #{project_id}: #{inspect(result)}")
          :ok

        {:error, reason} ->
          Logger.warning("Failed to add governance issue to project: #{inspect(reason)}")
          :ok
      end
    else
      _ -> :ok
    end
  end

  @doc """
  Auto-add an output PR to the configured project.

  Only operates if `default_project_id` is configured and
  `auto_add_output_prs` is true.

  Returns `:ok` (fire-and-forget).
  """
  @spec auto_add_output_pr(String.t()) :: :ok
  def auto_add_output_pr(pr_node_id) do
    with true <- auto_add_output_prs?(),
         project_id when not is_nil(project_id) <- default_project_id() do
      case GitHub.add_to_project(project_id, pr_node_id) do
        {:ok, _} ->
          :telemetry.execute(
            [:lattice, :github, :project_item_added],
            %{count: 1},
            %{project_id: project_id, content_type: :pull_request}
          )

          :ok

        {:error, reason} ->
          Logger.warning("Failed to add PR to project: #{inspect(reason)}")
          :ok
      end
    else
      _ -> :ok
    end
  end

  @doc """
  Update the project item's status field based on an intent state transition.

  Looks up the `status_mapping` to translate intent states to project status values.
  Only operates if a `default_project_id` is configured and the state has a mapping.

  Note: This requires the item_id to be known (stored in intent metadata).

  Returns `:ok` (fire-and-forget).
  """
  @spec update_status(String.t(), atom()) :: :ok
  def update_status(item_id, intent_state) do
    config = config()
    project_id = Keyword.get(config, :default_project_id)
    status_field = Keyword.get(config, :status_field_id)
    mapping = Keyword.get(config, :status_mapping, %{})

    status_value = Map.get(mapping, intent_state)

    if project_id && status_field && item_id && status_value do
      case GitHub.update_project_item_field(project_id, item_id, status_field, status_value) do
        {:ok, _} ->
          :telemetry.execute(
            [:lattice, :github, :project_item_updated],
            %{count: 1},
            %{project_id: project_id, item_id: item_id, status: status_value}
          )

          :ok

        {:error, reason} ->
          Logger.warning("Failed to update project item status: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc "Returns the configured default project ID, or nil."
  @spec default_project_id() :: String.t() | nil
  def default_project_id do
    Keyword.get(config(), :default_project_id)
  end

  @doc "Whether auto-adding governance issues is enabled."
  @spec auto_add_governance_issues?() :: boolean()
  def auto_add_governance_issues? do
    default_project_id() != nil && Keyword.get(config(), :auto_add_governance_issues, false)
  end

  @doc "Whether auto-adding output PRs is enabled."
  @spec auto_add_output_prs?() :: boolean()
  def auto_add_output_prs? do
    default_project_id() != nil && Keyword.get(config(), :auto_add_output_prs, false)
  end

  defp config do
    Application.get_env(:lattice, :github_projects, [])
  end
end
