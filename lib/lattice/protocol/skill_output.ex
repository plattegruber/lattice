defmodule Lattice.Protocol.SkillOutput do
  @moduledoc """
  Descriptor for a single output of a skill manifest.

  ## Fields

  - `name` -- the output name (required)
  - `type` -- data type as a string (e.g. "string", "integer", "map")
  - `description` -- human-readable description of the output
  """

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          description: String.t() | nil
        }

  @enforce_keys [:name, :type]
  defstruct [:name, :type, :description]

  @doc """
  Build a `%SkillOutput{}` from a decoded JSON map.

  Returns `{:ok, output}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{"name" => name, "type" => type} = map)
      when is_binary(name) and is_binary(type) do
    {:ok,
     %__MODULE__{
       name: name,
       type: type,
       description: Map.get(map, "description")
     }}
  end

  def from_map(_), do: {:error, "Output must have 'name' and 'type' fields"}
end
