defmodule Lattice.Context.Bundle do
  @moduledoc """
  Output struct from context gathering.

  Contains the manifest metadata, a list of file entries (path + content + kind),
  linked item references, expansion budget tracking, and any warnings.
  """

  @type file_entry :: %{path: String.t(), content: String.t(), kind: String.t()}

  @type linked_item :: %{type: String.t(), number: pos_integer(), title: String.t()}

  @type t :: %__MODULE__{
          trigger_type: :issue | :pull_request,
          trigger_number: pos_integer(),
          repo: String.t(),
          title: String.t(),
          gathered_at: DateTime.t(),
          files: [file_entry()],
          linked_items: [linked_item()],
          expansion_budget: %{used: non_neg_integer(), max: non_neg_integer()},
          warnings: [String.t()]
        }

  @enforce_keys [:trigger_type, :trigger_number, :repo, :title, :gathered_at]
  defstruct [
    :trigger_type,
    :trigger_number,
    :repo,
    :title,
    :gathered_at,
    files: [],
    linked_items: [],
    expansion_budget: %{used: 0, max: 5},
    warnings: []
  ]

  @doc """
  Create a new Bundle from a `Trigger`.
  """
  @spec new(Lattice.Context.Trigger.t(), keyword()) :: t()
  def new(%Lattice.Context.Trigger{} = trigger, opts \\ []) do
    max_expansions = Keyword.get(opts, :max_expansions, 5)

    %__MODULE__{
      trigger_type: trigger.type,
      trigger_number: trigger.number,
      repo: trigger.repo,
      title: trigger.title,
      gathered_at: DateTime.utc_now(),
      expansion_budget: %{used: 0, max: max_expansions}
    }
  end

  @doc """
  Add a file entry to the bundle.
  """
  @spec add_file(t(), String.t(), String.t(), String.t()) :: t()
  def add_file(%__MODULE__{} = bundle, path, content, kind) do
    entry = %{path: path, content: content, kind: kind}
    %{bundle | files: bundle.files ++ [entry]}
  end

  @doc """
  Add a linked item reference to the bundle and increment the expansion budget.
  """
  @spec add_linked_item(t(), String.t(), pos_integer(), String.t()) :: t()
  def add_linked_item(%__MODULE__{} = bundle, type, number, title) do
    item = %{type: type, number: number, title: title}
    budget = %{bundle.expansion_budget | used: bundle.expansion_budget.used + 1}
    %{bundle | linked_items: bundle.linked_items ++ [item], expansion_budget: budget}
  end

  @doc """
  Add a warning message to the bundle.
  """
  @spec add_warning(t(), String.t()) :: t()
  def add_warning(%__MODULE__{} = bundle, message) do
    %{bundle | warnings: bundle.warnings ++ [message]}
  end

  @doc """
  Check if the expansion budget has remaining capacity.
  """
  @spec budget_remaining?(t()) :: boolean()
  def budget_remaining?(%__MODULE__{expansion_budget: %{used: used, max: max}}) do
    used < max
  end

  @doc """
  Total byte size of all file contents in the bundle.
  """
  @spec total_size(t()) :: non_neg_integer()
  def total_size(%__MODULE__{files: files}) do
    Enum.reduce(files, 0, fn %{content: content}, acc ->
      acc + byte_size(content)
    end)
  end

  @doc """
  Convert the bundle to a JSON-encodable manifest map.
  """
  @spec to_manifest(t()) :: map()
  def to_manifest(%__MODULE__{} = bundle) do
    %{
      version: "v1",
      trigger_type: to_string(bundle.trigger_type),
      trigger_number: bundle.trigger_number,
      repo: bundle.repo,
      title: bundle.title,
      gathered_at: DateTime.to_iso8601(bundle.gathered_at),
      files:
        Enum.map(bundle.files, fn %{path: path, kind: kind} ->
          %{path: path, kind: kind}
        end),
      linked_items:
        Enum.map(bundle.linked_items, fn item ->
          %{type: item.type, number: item.number, title: item.title}
        end),
      expansion_budget: bundle.expansion_budget,
      warnings: bundle.warnings
    }
  end

  @doc """
  Convert the bundle to a pretty-printed JSON manifest string.
  """
  @spec to_manifest_json(t()) :: String.t()
  def to_manifest_json(%__MODULE__{} = bundle) do
    bundle
    |> to_manifest()
    |> Jason.encode!(pretty: true)
  end
end
