defmodule Lattice.Capabilities.GitHub.Project do
  @moduledoc """
  Represents a GitHub Projects v2 project.
  """

  @type field :: %{
          id: String.t(),
          name: String.t(),
          type: String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          url: String.t() | nil,
          fields: [field()]
        }

  @enforce_keys [:id, :title]
  defstruct [:id, :title, :description, :url, fields: []]

  @doc "Parse a project from a GraphQL response node."
  @spec from_graphql(map()) :: t()
  def from_graphql(data) when is_map(data) do
    fields =
      data
      |> get_in(["fields", "nodes"])
      |> List.wrap()
      |> Enum.map(fn f ->
        %{
          id: f["id"],
          name: f["name"],
          type: f["dataType"] || f["__typename"]
        }
      end)

    %__MODULE__{
      id: data["id"],
      title: data["title"],
      description: data["shortDescription"] || data["description"],
      url: data["url"],
      fields: fields
    }
  end
end
