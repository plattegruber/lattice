defmodule Lattice.Capabilities.GitHub.ProjectItem do
  @moduledoc """
  Represents an item (issue or PR) within a GitHub Projects v2 project.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          content_id: String.t() | nil,
          content_type: :issue | :pull_request | :draft_issue | :unknown,
          title: String.t() | nil,
          field_values: map()
        }

  @enforce_keys [:id]
  defstruct [:id, :content_id, :content_type, :title, field_values: %{}]

  @doc "Parse a project item from a GraphQL response node."
  @spec from_graphql(map()) :: t()
  def from_graphql(data) when is_map(data) do
    content = data["content"] || %{}

    content_type =
      case content["__typename"] do
        "Issue" -> :issue
        "PullRequest" -> :pull_request
        "DraftIssue" -> :draft_issue
        _ -> :unknown
      end

    field_values = parse_field_values(data)

    %__MODULE__{
      id: data["id"],
      content_id: content["id"],
      content_type: content_type,
      title: content["title"],
      field_values: field_values
    }
  end

  defp parse_field_values(data) do
    data
    |> get_in(["fieldValues", "nodes"])
    |> List.wrap()
    |> Enum.reduce(%{}, fn node, acc ->
      field_name = get_in(node, ["field", "name"])

      value =
        node["text"] || node["name"] || node["number"] || node["date"] || node["title"]

      if field_name do
        Map.put(acc, field_name, value)
      else
        acc
      end
    end)
  end
end
