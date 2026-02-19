defmodule Lattice.Policy.SpritePurpose do
  @moduledoc """
  Manages sprite purpose tagging — what repo a sprite works on and
  what kinds of tasks it handles.

  Stored via `Lattice.Store.ETS` under the `:sprite_purposes` namespace,
  keyed by sprite name.
  """

  alias Lattice.Store.ETS, as: MetadataStore

  @namespace :sprite_purposes

  @type t :: %__MODULE__{
          sprite_name: String.t(),
          repo: String.t() | nil,
          task_kinds: [String.t()],
          labels: [String.t()],
          notes: String.t() | nil
        }

  defstruct [
    :sprite_name,
    :repo,
    :notes,
    task_kinds: [],
    labels: []
  ]

  # ── Public API ──────────────────────────────────────────────────

  @doc "Set the purpose for a sprite."
  @spec put(t()) :: :ok
  def put(%__MODULE__{sprite_name: name} = purpose) when is_binary(name) do
    MetadataStore.put(@namespace, name, Map.from_struct(purpose))
  end

  @doc "Get the purpose for a sprite."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(sprite_name) when is_binary(sprite_name) do
    case MetadataStore.get(@namespace, sprite_name) do
      {:ok, data} when is_map(data) -> {:ok, from_map(data)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "List all sprite purposes."
  @spec list() :: {:ok, [t()]}
  def list do
    case MetadataStore.list(@namespace) do
      {:ok, items} ->
        purposes =
          items
          |> Enum.map(&from_map/1)
          |> Enum.sort_by(& &1.sprite_name)

        {:ok, purposes}
    end
  end

  @doc "Delete a sprite's purpose."
  @spec delete(String.t()) :: :ok
  def delete(sprite_name) when is_binary(sprite_name) do
    MetadataStore.delete(@namespace, sprite_name)
  end

  @doc "Serialize to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = purpose) do
    %{
      sprite_name: purpose.sprite_name,
      repo: purpose.repo,
      task_kinds: purpose.task_kinds,
      labels: purpose.labels,
      notes: purpose.notes
    }
  end

  @doc false
  def from_map(data) when is_map(data) do
    %__MODULE__{
      sprite_name: data[:sprite_name] || data["sprite_name"],
      repo: data[:repo] || data["repo"],
      task_kinds: data[:task_kinds] || data["task_kinds"] || [],
      labels: data[:labels] || data["labels"] || [],
      notes: data[:notes] || data["notes"]
    }
  end
end
