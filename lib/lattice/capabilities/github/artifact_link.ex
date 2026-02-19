defmodule Lattice.Capabilities.GitHub.ArtifactLink do
  @moduledoc """
  Represents a link between an intent/run and a GitHub artifact.

  Artifact links enable bidirectional traceability: from an intent to all
  GitHub entities it produced, and from any GitHub entity back to the
  intent that created it.
  """

  @type kind :: :issue | :pull_request | :branch | :commit
  @type role :: :governance | :output | :input | :related

  @type t :: %__MODULE__{
          intent_id: String.t(),
          run_id: String.t() | nil,
          kind: kind(),
          ref: String.t() | integer(),
          url: String.t() | nil,
          role: role(),
          created_at: DateTime.t()
        }

  @enforce_keys [:intent_id, :kind, :ref, :role]
  defstruct [:intent_id, :run_id, :kind, :ref, :url, :role, :created_at]

  @doc "Build a new ArtifactLink with current timestamp."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      intent_id: Map.fetch!(attrs, :intent_id),
      run_id: Map.get(attrs, :run_id),
      kind: Map.fetch!(attrs, :kind),
      ref: Map.fetch!(attrs, :ref),
      url: Map.get(attrs, :url),
      role: Map.fetch!(attrs, :role),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end
end
