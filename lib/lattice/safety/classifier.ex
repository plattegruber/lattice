defmodule Lattice.Safety.Classifier do
  @moduledoc """
  Classifies capability actions by their safety level.

  The Classifier maps `{capability, operation}` tuples to one of three
  classification levels:

  - `:safe` -- read-only operations with no side effects
  - `:controlled` -- state-mutating operations that require approval
  - `:dangerous` -- infrastructure-level operations requiring explicit opt-in

  ## Classification Criteria

  ### Safe Actions
  Read-only operations that only retrieve data. These never modify state
  or trigger side effects in external systems. Examples: listing sprites,
  fetching logs, getting status, reading secrets, listing GitHub issues.

  ### Controlled Actions
  Operations that mutate state in a bounded way. They change the state of
  a single resource but do not affect infrastructure. Examples: waking or
  sleeping a sprite, executing a command, creating/updating GitHub issues,
  adding labels.

  ### Dangerous Actions
  Operations that affect infrastructure or have wide-ranging effects.
  These require both a configuration opt-in and human approval. Examples:
  deploying applications, destroying resources, scaling infrastructure.

  ## Adding Classifications for New Capabilities

  When adding a new capability module, register its operations here by
  adding entries to the appropriate classification map. If an operation is
  not registered, `classify/2` returns `{:error, :unknown_action}`.
  """

  alias Lattice.Safety.Action

  # ── Classification Registry ────────────────────────────────────────

  @classifications %{
    # Sprites API
    {:sprites, :list_sprites} => :safe,
    {:sprites, :get_sprite} => :safe,
    {:sprites, :fetch_logs} => :safe,
    {:sprites, :wake} => :controlled,
    {:sprites, :sleep} => :controlled,
    {:sprites, :exec} => :controlled,
    {:sprites, :run_task} => :controlled,
    {:sprites, :delete_sprite} => :dangerous,
    # GitHub
    {:github, :list_issues} => :safe,
    {:github, :get_issue} => :safe,
    {:github, :create_issue} => :controlled,
    {:github, :update_issue} => :controlled,
    {:github, :add_label} => :controlled,
    {:github, :remove_label} => :controlled,
    {:github, :create_comment} => :controlled,
    # GitHub — PRs & Branches
    {:github, :list_pull_requests} => :safe,
    {:github, :get_pull_request} => :safe,
    {:github, :create_pull_request} => :controlled,
    {:github, :update_pull_request} => :controlled,
    {:github, :merge_pull_request} => :controlled,
    {:github, :create_branch} => :controlled,
    {:github, :delete_branch} => :controlled,
    # GitHub — Reviews
    {:github, :list_reviews} => :safe,
    {:github, :list_review_comments} => :safe,
    {:github, :create_review_comment} => :controlled,
    # GitHub — Assignments
    {:github, :assign_issue} => :controlled,
    {:github, :unassign_issue} => :controlled,
    {:github, :request_review} => :controlled,
    {:github, :list_collaborators} => :safe,
    # GitHub — Projects v2
    {:github, :list_projects} => :safe,
    {:github, :get_project} => :safe,
    {:github, :list_project_items} => :safe,
    {:github, :add_to_project} => :controlled,
    {:github, :update_project_item_field} => :controlled,
    # Fly.io
    {:fly, :logs} => :safe,
    {:fly, :machine_status} => :safe,
    {:fly, :deploy} => :dangerous,
    # Secret Store
    {:secret_store, :get_secret} => :safe
  }

  @doc """
  Classify a capability operation and return an Action struct.

  Returns `{:ok, %Action{}}` if the operation is registered, or
  `{:error, :unknown_action}` if it is not.

  ## Examples

      iex> Lattice.Safety.Classifier.classify(:sprites, :list_sprites)
      {:ok, %Lattice.Safety.Action{capability: :sprites, operation: :list_sprites, classification: :safe}}

      iex> Lattice.Safety.Classifier.classify(:sprites, :wake)
      {:ok, %Lattice.Safety.Action{capability: :sprites, operation: :wake, classification: :controlled}}

      iex> Lattice.Safety.Classifier.classify(:fly, :deploy)
      {:ok, %Lattice.Safety.Action{capability: :fly, operation: :deploy, classification: :dangerous}}

      iex> Lattice.Safety.Classifier.classify(:unknown, :unknown)
      {:error, :unknown_action}

  """
  @spec classify(atom(), atom()) :: {:ok, Action.t()} | {:error, :unknown_action}
  def classify(capability, operation) do
    case Map.get(@classifications, {capability, operation}) do
      nil -> {:error, :unknown_action}
      classification -> Action.new(capability, operation, classification)
    end
  end

  @doc """
  Returns the classification level for a capability operation, or `:unknown`.

  A convenience function when you only need the atom, not the full Action struct.

  ## Examples

      iex> Lattice.Safety.Classifier.classification_for(:sprites, :list_sprites)
      :safe

      iex> Lattice.Safety.Classifier.classification_for(:unknown, :op)
      :unknown

  """
  @spec classification_for(atom(), atom()) :: Action.classification() | :unknown
  def classification_for(capability, operation) do
    Map.get(@classifications, {capability, operation}, :unknown)
  end

  @doc """
  Returns all registered `{capability, operation}` pairs for a given
  classification level.

  ## Examples

      iex> Lattice.Safety.Classifier.actions_for(:dangerous)
      [{:fly, :deploy}]

  """
  @spec actions_for(Action.classification()) :: [{atom(), atom()}]
  def actions_for(classification) do
    @classifications
    |> Enum.filter(fn {_key, value} -> value == classification end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
  end

  @doc """
  Returns the full classification registry as a map.

  Useful for introspection, documentation, and admin dashboards.
  """
  @spec all_classifications() :: %{{atom(), atom()} => Action.classification()}
  def all_classifications, do: @classifications
end
