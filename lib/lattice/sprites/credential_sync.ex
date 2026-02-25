defmodule Lattice.Sprites.CredentialSync do
  @moduledoc """
  Syncs Claude OAuth credentials from a source sprite to all managed sprites.

  Reads `~/.claude/.credentials.json` from the configured source sprite and
  writes it to every other sprite in the fleet. This keeps OAuth tokens fresh
  across the fleet without waiting for a just-in-time sync at `claude -p` time.

  ## Configuration

      config :lattice, Lattice.Ambient.SpriteDelegate,
        credentials_source_sprite: "lattice-ambient"
  """

  require Logger

  alias Lattice.Capabilities.Sprites

  @creds_path "/home/sprite/.claude/.credentials.json"

  @doc """
  Sync credentials from the configured source sprite to all fleet sprites.

  Returns a map of `%{sprite_name => :ok | {:error, reason}}`.
  Returns an empty map when no source sprite is configured.
  """
  @spec sync_all() :: %{String.t() => :ok | {:error, term()}}
  def sync_all do
    source = credentials_source_sprite()

    if is_nil(source) or source == "" do
      Logger.info("CredentialSync: no source sprite configured, skipping")
      %{}
    else
      do_sync_all(source)
    end
  end

  @doc """
  Sync credentials from `source` sprite to a single `target` sprite.

  Returns `:ok` on success, `{:error, reason}` on failure.
  No-op (returns `:ok`) when source == target.
  """
  @spec sync_one(String.t(), String.t()) :: :ok | {:error, term()}
  def sync_one(source, target) when source == target, do: :ok

  def sync_one(source, target) do
    Logger.info("CredentialSync: syncing from #{source} to #{target}")

    with {:ok, creds} <- read_credentials(source),
         :ok <- write_credentials(target, creds) do
      Logger.info("CredentialSync: credentials synced to #{target}")
      :ok
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp do_sync_all(source) do
    with {:ok, sprites} <- Sprites.list_sprites(),
         {:ok, creds} <- read_credentials(source) do
      targets =
        sprites
        |> Enum.map(fn s -> s[:name] || s[:id] end)
        |> Enum.reject(&(&1 == source))

      Logger.info(
        "CredentialSync: syncing from #{source} to #{length(targets)} sprite(s)"
      )

      Map.new(targets, fn name ->
        {name, write_credentials(name, creds)}
      end)
    else
      {:error, reason} ->
        Logger.warning("CredentialSync: failed during sync_all: #{inspect(reason)}")
        %{}
    end
  end

  @doc false
  def read_credentials(source) do
    case Sprites.exec(source, "cat #{@creds_path}") do
      {:ok, %{exit_code: 0, output: creds}} when creds != "" ->
        {:ok, String.trim(creds)}

      {:ok, %{exit_code: code}} ->
        Logger.warning("CredentialSync: failed to read credentials from #{source}: exit=#{code}")
        {:error, :credentials_read_failed}

      {:error, reason} ->
        Logger.warning(
          "CredentialSync: failed to read credentials from #{source}: #{inspect(reason)}"
        )

        {:error, :credentials_read_failed}
    end
  end

  @doc false
  def write_credentials(target, creds) do
    write_cmd =
      "mkdir -p /home/sprite/.claude && " <>
        "cat > #{@creds_path} << 'LATTICE_CREDS_EOF'\n#{creds}\nLATTICE_CREDS_EOF\n" <>
        "chmod 600 #{@creds_path}"

    case Sprites.exec(target, write_cmd) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, output: output}} ->
        Logger.warning(
          "CredentialSync: failed to write credentials to #{target}: exit=#{code} #{output}"
        )

        {:error, :credentials_write_failed}

      {:error, reason} ->
        Logger.warning(
          "CredentialSync: failed to write credentials to #{target}: #{inspect(reason)}"
        )

        {:error, :credentials_write_failed}
    end
  end

  defp credentials_source_sprite do
    Application.get_env(:lattice, Lattice.Ambient.SpriteDelegate, [])
    |> Keyword.get(:credentials_source_sprite, nil)
  end
end
