defmodule Lattice.Runs.Store do
  @moduledoc """
  Persistence for Run entities using the generic ETS store.

  Provides CRUD operations and filtered queries for Runs. Delegates to
  `Lattice.Store` (ETS-backed) with the `:runs` namespace.

  Note: The generic store adds internal metadata keys (`_key`, `_namespace`,
  `_updated_at`) to stored values. This module strips those on retrieval
  so callers always receive clean `%Run{}` structs.

  ## Filtering

  Supports filtering by `:intent_id`, `:sprite_name`, and `:status`.
  Results are sorted newest-first by `inserted_at`.
  """

  alias Lattice.Runs.Run

  @namespace :runs
  @store_metadata_keys [:_key, :_namespace, :_updated_at]

  @doc "Persist a new Run."
  @spec create(Run.t()) :: {:ok, Run.t()}
  def create(%Run{} = run) do
    Lattice.Store.put(@namespace, run.id, run)
    {:ok, run}
  end

  @doc "Retrieve a Run by ID."
  @spec get(String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def get(run_id) when is_binary(run_id) do
    case Lattice.Store.get(@namespace, run_id) do
      {:ok, value} -> {:ok, strip_store_metadata(value)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Update a Run in the store."
  @spec update(Run.t()) :: {:ok, Run.t()}
  def update(%Run{} = run) do
    Lattice.Store.put(@namespace, run.id, run)
    {:ok, run}
  end

  @doc """
  List Runs with optional filters.

  ## Supported Filters

  - `:intent_id` — filter by associated intent
  - `:sprite_name` — filter by sprite name
  - `:status` — filter by run status
  """
  @spec list(map()) :: {:ok, [Run.t()]}
  def list(filters \\ %{}) do
    {:ok, all} = Lattice.Store.list(@namespace)

    runs =
      all
      |> Enum.map(&strip_store_metadata/1)
      |> apply_filters(filters)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    {:ok, runs}
  end

  @doc "List Runs associated with a specific intent."
  @spec list_by_intent(String.t()) :: {:ok, [Run.t()]}
  def list_by_intent(intent_id) when is_binary(intent_id) do
    list(%{intent_id: intent_id})
  end

  @doc "List Runs associated with a specific sprite."
  @spec list_by_sprite(String.t()) :: {:ok, [Run.t()]}
  def list_by_sprite(sprite_name) when is_binary(sprite_name) do
    list(%{sprite_name: sprite_name})
  end

  @doc "Delete a Run by ID."
  @spec delete(String.t()) :: :ok
  def delete(run_id) when is_binary(run_id) do
    Lattice.Store.delete(@namespace, run_id)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp strip_store_metadata(value) do
    Map.drop(value, @store_metadata_keys)
  end

  defp apply_filters(runs, filters) do
    Enum.reduce(filters, runs, fn
      {:intent_id, id}, acc -> Enum.filter(acc, &(&1.intent_id == id))
      {:sprite_name, name}, acc -> Enum.filter(acc, &(&1.sprite_name == name))
      {:status, status}, acc -> Enum.filter(acc, &(&1.status == status))
      _, acc -> acc
    end)
  end
end
