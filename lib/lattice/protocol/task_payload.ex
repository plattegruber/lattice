defmodule Lattice.Protocol.TaskPayload do
  @moduledoc """
  Structured input contract for sprite task assignment.

  Defines the data sprites receive via `/workspace/.lattice/task.json`.
  """

  @type t :: %__MODULE__{
          run_id: String.t(),
          goal: String.t(),
          repo: String.t() | nil,
          skill: String.t() | nil,
          constraints: map(),
          acceptance: String.t() | nil,
          answers: map(),
          env: map()
        }

  @enforce_keys [:run_id, :goal]
  defstruct [
    :run_id,
    :goal,
    :repo,
    :skill,
    :acceptance,
    constraints: %{},
    answers: %{},
    env: %{}
  ]

  @doc "Create a new TaskPayload from a map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, [atom()]}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    missing =
      Enum.filter([:run_id, :goal], fn key ->
        val = Map.get(attrs, key) || Map.get(attrs, to_string(key))
        is_nil(val) or val == ""
      end)

    if missing != [] do
      {:error, missing}
    else
      {:ok,
       %__MODULE__{
         run_id: get_field(attrs, :run_id),
         goal: get_field(attrs, :goal),
         repo: get_field(attrs, :repo),
         skill: get_field(attrs, :skill),
         constraints: get_field(attrs, :constraints) || %{},
         acceptance: get_field(attrs, :acceptance),
         answers: get_field(attrs, :answers) || %{},
         env: get_field(attrs, :env) || %{}
       }}
    end
  end

  @doc "Validate a TaskPayload struct."
  @spec validate(t()) :: {:ok, t()} | {:error, [atom()]}
  def validate(%__MODULE__{} = payload) do
    missing = []

    missing =
      if is_nil(payload.run_id) or payload.run_id == "", do: [:run_id | missing], else: missing

    missing = if is_nil(payload.goal) or payload.goal == "", do: [:goal | missing], else: missing

    if missing == [] do
      {:ok, payload}
    else
      {:error, Enum.reverse(missing)}
    end
  end

  @doc "Serialize a TaskPayload to a JSON string."
  @spec serialize(t()) :: {:ok, String.t()} | {:error, term()}
  def serialize(%__MODULE__{} = payload) do
    map = %{
      run_id: payload.run_id,
      goal: payload.goal,
      repo: payload.repo,
      skill: payload.skill,
      constraints: payload.constraints,
      acceptance: payload.acceptance,
      answers: payload.answers,
      env: payload.env
    }

    case Jason.encode(map) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deserialize a JSON string to a TaskPayload."
  @spec deserialize(String.t()) :: {:ok, t()} | {:error, term()}
  def deserialize(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> new(map)
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_field(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end
end
