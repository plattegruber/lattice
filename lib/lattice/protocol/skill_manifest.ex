defmodule Lattice.Protocol.SkillManifest do
  @moduledoc """
  Schema for a skill manifest discovered on a sprite.

  Skills are self-describing units of work that a sprite can execute.
  Each skill exposes a `skill.json` file under `/skills/<name>/skill.json`
  on the sprite filesystem, containing the manifest.

  ## Fields

  - `name` -- unique skill identifier (required)
  - `description` -- human-readable description
  - `inputs` -- list of `%SkillInput{}` descriptors
  - `outputs` -- list of `%SkillOutput{}` descriptors
  - `permissions` -- list of permission strings the skill requires
  - `produces_events` -- whether the skill emits LATTICE_EVENT protocol events
  """

  alias Lattice.Protocol.SkillInput
  alias Lattice.Protocol.SkillOutput

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          inputs: [SkillInput.t()],
          outputs: [SkillOutput.t()],
          permissions: [String.t()],
          produces_events: boolean()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :description,
    inputs: [],
    outputs: [],
    permissions: [],
    produces_events: false
  ]

  @doc """
  Parse a decoded JSON map into a `%SkillManifest{}`.

  Returns `{:ok, manifest}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{"name" => name} = map) when is_binary(name) and name != "" do
    with {:ok, inputs} <- parse_inputs(Map.get(map, "inputs", [])),
         {:ok, outputs} <- parse_outputs(Map.get(map, "outputs", [])) do
      {:ok,
       %__MODULE__{
         name: name,
         description: Map.get(map, "description"),
         inputs: inputs,
         outputs: outputs,
         permissions: Map.get(map, "permissions", []),
         produces_events: Map.get(map, "produces_events", false)
       }}
    end
  end

  def from_map(_), do: {:error, "Manifest must have a non-empty 'name' field"}

  @doc """
  Validate a proposed input map against a manifest's input descriptors.

  Checks that:
  1. All required inputs are present.
  2. Provided values match the declared type.

  Returns `:ok` or `{:error, errors}` where `errors` is a list of
  `{field_name, reason}` tuples.
  """
  @spec validate_inputs(t(), map()) :: :ok | {:error, [{String.t(), String.t()}]}
  def validate_inputs(%__MODULE__{inputs: inputs}, input_map) when is_map(input_map) do
    errors =
      inputs
      |> Enum.flat_map(fn %SkillInput{} = input ->
        value = Map.get(input_map, input.name)
        validate_single_input(input, value)
      end)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp validate_single_input(%SkillInput{name: name, required: true}, nil) do
    [{name, "is required"}]
  end

  defp validate_single_input(%SkillInput{}, nil), do: []

  defp validate_single_input(%SkillInput{name: name, type: type}, value) do
    if type_matches?(type, value) do
      []
    else
      [{name, "expected type #{type}, got #{inspect(value)}"}]
    end
  end

  defp type_matches?(:string, value), do: is_binary(value)
  defp type_matches?(:integer, value), do: is_integer(value)
  defp type_matches?(:boolean, value), do: is_boolean(value)
  defp type_matches?(:map, value), do: is_map(value)

  defp parse_inputs(items) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case SkillInput.from_map(item) do
        {:ok, input} -> {:cont, {:ok, acc ++ [input]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_inputs(_), do: {:ok, []}

  defp parse_outputs(items) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case SkillOutput.from_map(item) do
        {:ok, output} -> {:cont, {:ok, acc ++ [output]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_outputs(_), do: {:ok, []}
end
