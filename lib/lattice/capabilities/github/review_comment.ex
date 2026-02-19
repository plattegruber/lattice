defmodule Lattice.Capabilities.GitHub.ReviewComment do
  @moduledoc """
  Struct representing an inline review comment on a pull request.

  Inline comments are tied to a specific `path` and `line` in a commit.
  Threads are linked via `in_reply_to_id`.
  """

  @type t :: %__MODULE__{
          id: integer(),
          path: String.t(),
          line: integer() | nil,
          body: String.t(),
          author: String.t(),
          created_at: String.t(),
          in_reply_to_id: integer() | nil,
          commit_id: String.t() | nil
        }

  @enforce_keys [:id, :body, :author]
  defstruct [:id, :path, :line, :body, :author, :created_at, :in_reply_to_id, :commit_id]

  @doc "Build a ReviewComment from a GitHub API JSON map."
  @spec from_json(map()) :: t()
  def from_json(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      path: data["path"],
      line: data["line"] || data["original_line"],
      body: data["body"] || "",
      author: get_in(data, ["user", "login"]) || data["author"] || "",
      created_at: data["created_at"] || data["createdAt"],
      in_reply_to_id: data["in_reply_to_id"],
      commit_id: data["commit_id"] || data["original_commit_id"]
    }
  end
end
