defmodule Lattice.Protocol.SkillInput do
  @moduledoc """
  Descriptor for a single input parameter of a skill manifest.

  ## Fields

  - `name` -- the parameter name (required)
  - `type` -- data type: `:string`, `:integer`, `:boolean`, or `:map`
  - `required` -- whether this input must be provided (default `true`)
  - `description` -- human-readable description of the parameter
  - `default` -- default value when the input is not provided
  """

  @type input_type :: :string | :integer | :boolean | :map

  @type t :: %__MODULE__{
          name: String.t(),
          type: input_type(),
          required: boolean(),
          description: String.t() | nil,
          default: term()
        }

  @enforce_keys [:name, :type]
  defstruct [:name, :type, :description, :default, required: true]

  @valid_types ~w(string integer boolean map)a

  @doc """
  Build a `%SkillInput{}` from a decoded JSON map.

  Returns `{:ok, input}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{"name" => name, "type" => type_str} = map) when is_binary(name) do
    case parse_type(type_str) do
      {:ok, type} ->
        {:ok,
         %__MODULE__{
           name: name,
           type: type,
           required: Map.get(map, "required", true),
           description: Map.get(map, "description"),
           default: Map.get(map, "default")
         }}

      :error ->
        {:error, "Invalid input type: #{inspect(type_str)}"}
    end
  end

  def from_map(_), do: {:error, "Input must have 'name' and 'type' fields"}

  @doc false
  defp parse_type(type_str) when is_binary(type_str) do
    atom = String.to_existing_atom(type_str)

    if atom in @valid_types do
      {:ok, atom}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_type(_), do: :error
end
