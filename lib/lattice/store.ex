defmodule Lattice.Store do
  @moduledoc """
  Behaviour for key-value metadata storage.

  Provides a namespace-scoped key-value store for Lattice-local metadata
  (tags, purpose, labels) that is not owned by external systems like the
  Sprites API.

  ## Migration Path

  The default implementation is `Lattice.Store.ETS` (in-memory, lost on
  restart). A PostgreSQL-backed implementation can be swapped in later via
  config:

      config :lattice, :store, Lattice.Store.Postgres
  """

  @type namespace :: atom()
  @type key :: String.t()
  @type value :: map()

  @callback put(namespace, key, value) :: :ok | {:error, term()}
  @callback get(namespace, key) :: {:ok, value} | {:error, :not_found}
  @callback list(namespace) :: {:ok, [value]}
  @callback delete(namespace, key) :: :ok

  @doc "Returns the configured store implementation module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:lattice, :store, Lattice.Store.ETS)
  end

  @doc "Store a value under the given namespace and key."
  @spec put(namespace, key, value) :: :ok | {:error, term()}
  def put(ns, key, value), do: impl().put(ns, key, value)

  @doc "Retrieve a value by namespace and key."
  @spec get(namespace, key) :: {:ok, value} | {:error, :not_found}
  def get(ns, key), do: impl().get(ns, key)

  @doc "List all values in a namespace."
  @spec list(namespace) :: {:ok, [value]}
  def list(ns), do: impl().list(ns)

  @doc "Delete a value by namespace and key."
  @spec delete(namespace, key) :: :ok
  def delete(ns, key), do: impl().delete(ns, key)
end
