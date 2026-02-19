defmodule Lattice.Capabilities.GitHub do
  @moduledoc """
  Behaviour for interacting with the GitHub API.

  GitHub is used as the human-in-the-loop substrate for Lattice. Issues serve
  as approval workflows, labels indicate action status, and comments provide
  an audit trail.

  All callbacks return tagged tuples (`{:ok, result}` / `{:error, reason}`).
  """

  @typedoc "A GitHub issue or pull request number."
  @type issue_number :: pos_integer()

  @typedoc "Attributes for creating or updating an issue."
  @type issue_attrs :: map()

  @typedoc "A label name string."
  @type label :: String.t()

  @typedoc "A comment body string."
  @type comment_body :: String.t()

  @typedoc "Filter options for listing issues."
  @type list_opts :: keyword()

  @typedoc "A map representing a GitHub issue."
  @type issue :: map()

  @typedoc "A map representing a GitHub comment."
  @type comment :: map()

  @typedoc "A pull request number."
  @type pr_number :: pos_integer()

  @typedoc "Attributes for creating or updating a pull request."
  @type pr_attrs :: map()

  @typedoc "A map representing a GitHub pull request."
  @type pull_request :: map()

  @typedoc "Filter options for listing pull requests."
  @type pr_list_opts :: keyword()

  @typedoc "A git branch name."
  @type branch_name :: String.t()

  @doc "Create a new GitHub issue with the given attributes."
  @callback create_issue(String.t(), issue_attrs()) :: {:ok, issue()} | {:error, term()}

  @doc "Update an existing GitHub issue."
  @callback update_issue(issue_number(), issue_attrs()) :: {:ok, issue()} | {:error, term()}

  @doc "Add a label to an issue."
  @callback add_label(issue_number(), label()) :: {:ok, [label()]} | {:error, term()}

  @doc "Remove a label from an issue."
  @callback remove_label(issue_number(), label()) :: {:ok, [label()]} | {:error, term()}

  @doc "Create a comment on an issue."
  @callback create_comment(issue_number(), comment_body()) ::
              {:ok, comment()} | {:error, term()}

  @doc "List issues, optionally filtered by labels or other criteria."
  @callback list_issues(list_opts()) :: {:ok, [issue()]} | {:error, term()}

  @doc "Get a single issue by number."
  @callback get_issue(issue_number()) :: {:ok, issue()} | {:error, term()}

  @doc "Create a pull request."
  @callback create_pull_request(pr_attrs()) :: {:ok, pull_request()} | {:error, term()}

  @doc "Get a pull request by number."
  @callback get_pull_request(pr_number()) :: {:ok, pull_request()} | {:error, term()}

  @doc "Update an existing pull request."
  @callback update_pull_request(pr_number(), pr_attrs()) ::
              {:ok, pull_request()} | {:error, term()}

  @doc "Merge a pull request."
  @callback merge_pull_request(pr_number(), keyword()) ::
              {:ok, pull_request()} | {:error, term()}

  @doc "List pull requests, optionally filtered."
  @callback list_pull_requests(pr_list_opts()) :: {:ok, [pull_request()]} | {:error, term()}

  @doc "Create a new branch from a base ref."
  @callback create_branch(branch_name(), branch_name()) :: :ok | {:error, term()}

  @doc "Delete a branch."
  @callback delete_branch(branch_name()) :: :ok | {:error, term()}

  @doc "List reviews on a pull request."
  @callback list_reviews(pr_number()) :: {:ok, [map()]} | {:error, term()}

  @doc "List inline review comments on a pull request."
  @callback list_review_comments(pr_number()) :: {:ok, [map()]} | {:error, term()}

  @doc "Create an inline review comment on a pull request."
  @callback create_review_comment(pr_number(), String.t(), String.t(), integer(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Assign users to an issue."
  @callback assign_issue(issue_number(), [String.t()]) :: {:ok, issue()} | {:error, term()}

  @doc "Remove assignees from an issue."
  @callback unassign_issue(issue_number(), [String.t()]) :: {:ok, issue()} | {:error, term()}

  @doc "Request PR review from specific users."
  @callback request_review(pr_number(), [String.t()]) :: :ok | {:error, term()}

  @doc "List repository collaborators."
  @callback list_collaborators(keyword()) :: {:ok, [map()]} | {:error, term()}

  @doc "Create a new GitHub issue with the given attributes."
  def create_issue(title, attrs), do: impl().create_issue(title, attrs)

  @doc "Update an existing GitHub issue."
  def update_issue(number, attrs), do: impl().update_issue(number, attrs)

  @doc "Add a label to an issue."
  def add_label(number, label), do: impl().add_label(number, label)

  @doc "Remove a label from an issue."
  def remove_label(number, label), do: impl().remove_label(number, label)

  @doc "Create a comment on an issue."
  def create_comment(number, body), do: impl().create_comment(number, body)

  @doc "List issues, optionally filtered by labels or other criteria."
  def list_issues(opts \\ []), do: impl().list_issues(opts)

  @doc "Get a single issue by number."
  def get_issue(number), do: impl().get_issue(number)

  @doc "Create a pull request."
  def create_pull_request(attrs), do: impl().create_pull_request(attrs)

  @doc "Get a pull request by number."
  def get_pull_request(number), do: impl().get_pull_request(number)

  @doc "Update an existing pull request."
  def update_pull_request(number, attrs), do: impl().update_pull_request(number, attrs)

  @doc "Merge a pull request."
  def merge_pull_request(number, opts \\ []), do: impl().merge_pull_request(number, opts)

  @doc "List pull requests, optionally filtered."
  def list_pull_requests(opts \\ []), do: impl().list_pull_requests(opts)

  @doc "Create a new branch from a base ref."
  def create_branch(name, base), do: impl().create_branch(name, base)

  @doc "Delete a branch."
  def delete_branch(name), do: impl().delete_branch(name)

  @doc "List reviews on a pull request."
  def list_reviews(pr_number), do: impl().list_reviews(pr_number)

  @doc "List inline review comments on a pull request."
  def list_review_comments(pr_number), do: impl().list_review_comments(pr_number)

  @doc "Create an inline review comment on a pull request."
  def create_review_comment(pr_number, body, path, line, opts \\ []),
    do: impl().create_review_comment(pr_number, body, path, line, opts)

  @doc "Assign users to an issue."
  def assign_issue(number, usernames), do: impl().assign_issue(number, usernames)

  @doc "Remove assignees from an issue."
  def unassign_issue(number, usernames), do: impl().unassign_issue(number, usernames)

  @doc "Request PR review from specific users."
  def request_review(pr_number, usernames), do: impl().request_review(pr_number, usernames)

  @doc "List repository collaborators."
  def list_collaborators(opts \\ []), do: impl().list_collaborators(opts)

  defp impl, do: Application.get_env(:lattice, :capabilities)[:github]
end
