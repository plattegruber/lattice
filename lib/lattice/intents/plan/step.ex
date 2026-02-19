defmodule Lattice.Intents.Plan.Step do
  @moduledoc """
  A single step within an execution plan.

  Each step represents one discrete operation in a plan. Steps track their own
  status independently, enabling fine-grained progress reporting.

  ## Statuses

  - `:pending` — not yet started
  - `:running` — currently executing
  - `:completed` — finished successfully
  - `:failed` — finished with an error
  - `:skipped` — intentionally skipped
  """

  @valid_statuses [:pending, :running, :completed, :failed, :skipped]

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          skill: String.t() | nil,
          inputs: map(),
          status: :pending | :running | :completed | :failed | :skipped,
          output: term()
        }

  @enforce_keys [:id, :description]
  defstruct [:id, :description, :skill, :output, inputs: %{}, status: :pending]

  @doc """
  Create a new step with a description and optional fields.

  ## Options

  - `:id` — custom step ID (auto-generated if omitted)
  - `:skill` — the skill/capability this step uses
  - `:inputs` — input parameters for execution
  """
  @spec new(String.t(), keyword()) :: {:ok, t()}
  def new(description, opts \\ []) when is_binary(description) do
    {:ok,
     %__MODULE__{
       id: Keyword.get(opts, :id, generate_id()),
       description: description,
       skill: Keyword.get(opts, :skill),
       inputs: Keyword.get(opts, :inputs, %{})
     }}
  end

  @doc "Returns all valid step statuses."
  @spec valid_statuses() :: [atom()]
  def valid_statuses, do: @valid_statuses

  @doc "Convert a Step struct to a plain map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = step) do
    %{
      id: step.id,
      description: step.description,
      skill: step.skill,
      inputs: step.inputs,
      status: step.status,
      output: step.output
    }
  end

  @doc "Reconstruct a Step from a string-keyed map."
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_step}
  def from_map(%{"id" => id, "description" => description} = map)
      when is_binary(id) and is_binary(description) do
    status =
      case Map.get(map, "status", "pending") do
        s when is_binary(s) -> String.to_existing_atom(s)
        s when is_atom(s) -> s
      end

    {:ok,
     %__MODULE__{
       id: id,
       description: description,
       skill: Map.get(map, "skill"),
       inputs: Map.get(map, "inputs", %{}),
       status: status,
       output: Map.get(map, "output")
     }}
  rescue
    ArgumentError -> {:error, :invalid_step}
  end

  def from_map(_), do: {:error, :invalid_step}

  defp generate_id do
    "step_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
