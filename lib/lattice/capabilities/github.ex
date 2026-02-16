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

  defp impl, do: Application.get_env(:lattice, :capabilities)[:github]
end
