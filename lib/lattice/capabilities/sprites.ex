defmodule Lattice.Capabilities.Sprites do
  @moduledoc """
  Behaviour for interacting with the Sprites API.

  Sprites are AI coding agents managed by Lattice. This capability defines
  the interface for listing, inspecting, and controlling Sprites via the
  external Sprites API.

  All callbacks return tagged tuples (`{:ok, result}` / `{:error, reason}`).
  """

  @typedoc "Unique identifier for a Sprite."
  @type sprite_id :: String.t()

  @typedoc "A map representing a Sprite's data from the API."
  @type sprite :: map()

  @typedoc "A command string to execute on a Sprite."
  @type command :: String.t()

  @typedoc "Options for fetching logs."
  @type log_opts :: keyword()

  @doc "List all Sprites visible to this Lattice instance."
  @callback list_sprites() :: {:ok, [sprite()]} | {:error, term()}

  @doc "Get details for a single Sprite by ID."
  @callback get_sprite(sprite_id()) :: {:ok, sprite()} | {:error, term()}

  @doc "Wake (start) a sleeping Sprite."
  @callback wake(sprite_id()) :: {:ok, sprite()} | {:error, term()}

  @doc "Put a Sprite to sleep (stop)."
  @callback sleep(sprite_id()) :: {:ok, sprite()} | {:error, term()}

  @doc "Execute a command on a Sprite."
  @callback exec(sprite_id(), command()) :: {:ok, map()} | {:error, term()}

  @doc "Create a new Sprite with the given name."
  @callback create_sprite(name :: String.t(), opts :: keyword()) ::
              {:ok, sprite()} | {:error, term()}

  @doc "Delete a Sprite by ID. Idempotent: succeeds even if the Sprite does not exist."
  @callback delete_sprite(sprite_id()) :: :ok | {:error, term()}

  @doc "Fetch logs for a Sprite. Options may include `:since`, `:limit`, etc."
  @callback fetch_logs(sprite_id(), log_opts()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "List all Sprites visible to this Lattice instance."
  def list_sprites, do: impl().list_sprites()

  @doc "Get details for a single Sprite by ID."
  def get_sprite(id), do: impl().get_sprite(id)

  @doc "Wake (start) a sleeping Sprite."
  def wake(id), do: impl().wake(id)

  @doc "Put a Sprite to sleep (stop)."
  def sleep(id), do: impl().sleep(id)

  @doc "Execute a command on a Sprite."
  def exec(id, command), do: impl().exec(id, command)

  @doc "Create a new Sprite with the given name."
  def create_sprite(name, opts \\ []), do: impl().create_sprite(name, opts)

  @doc "Delete a Sprite by ID."
  def delete_sprite(id), do: impl().delete_sprite(id)

  @doc "Fetch logs for a Sprite."
  def fetch_logs(id, opts \\ []), do: impl().fetch_logs(id, opts)

  defp impl, do: Application.get_env(:lattice, :capabilities)[:sprites]
end
