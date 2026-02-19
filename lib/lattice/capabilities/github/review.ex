defmodule Lattice.Capabilities.GitHub.Review do
  @moduledoc """
  Struct representing a GitHub pull request review.

  A review has a verdict (`state`) of `:approved`, `:changes_requested`,
  or `:commented`, along with optional body text.
  """

  @type t :: %__MODULE__{
          id: integer(),
          author: String.t(),
          state: :approved | :changes_requested | :commented,
          body: String.t(),
          submitted_at: String.t()
        }

  @enforce_keys [:id, :author, :state]
  defstruct [:id, :author, :state, :submitted_at, body: ""]

  @doc "Build a Review from a GitHub API JSON map."
  @spec from_json(map()) :: t()
  def from_json(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      author: get_in(data, ["user", "login"]) || data["author"] || "",
      state: parse_state(data["state"]),
      body: data["body"] || "",
      submitted_at: data["submitted_at"] || data["submittedAt"]
    }
  end

  defp parse_state("APPROVED"), do: :approved
  defp parse_state("CHANGES_REQUESTED"), do: :changes_requested
  defp parse_state("COMMENTED"), do: :commented
  defp parse_state(_), do: :commented
end
