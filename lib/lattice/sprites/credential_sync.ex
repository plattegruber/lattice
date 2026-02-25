defmodule Lattice.Sprites.CredentialSync do
  @moduledoc """
  Syncs Claude OAuth credentials from a source sprite to configured targets.

  Reads `~/.claude/.credentials.json` from the configured source sprite and
  writes it to each target sprite. This keeps OAuth tokens fresh without
  waiting for a just-in-time sync at `claude -p` time.

  ## Configuration

      config :lattice, Lattice.Ambient.SpriteDelegate,
        credentials_source_sprite: "lattice-ambient",
        credentials_target_sprites: ["lattice-ephemeral"]
  """

  require Logger

  alias Lattice.Capabilities.Sprites

  @creds_path "/home/sprite/.claude/.credentials.json"
  @delegate_config Lattice.Ambient.SpriteDelegate

  @doc """
  Sync credentials from the configured source sprite to configured targets.

  Returns a map of `%{sprite_name => :ok | {:error, reason}}`.
  Returns an empty map when no source or targets are configured.
  """
  @spec sync_all() :: %{String.t() => :ok | {:error, term()}}
  def sync_all do
    source = credentials_source_sprite()
    targets = credentials_target_sprites()

    cond do
      is_nil(source) or source == "" ->
        Logger.info("CredentialSync: no source sprite configured, skipping")
        %{}

      targets == [] ->
        Logger.info("CredentialSync: no target sprites configured, skipping")
        %{}

      true ->
        do_sync_all(source, targets)
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

  defp do_sync_all(source, targets) do
    case read_credentials(source) do
      {:ok, creds} ->
        Logger.info("CredentialSync: syncing from #{source} to #{length(targets)} sprite(s)")

        Map.new(targets, fn name ->
          {name, write_credentials(name, creds)}
        end)

      {:error, reason} ->
        Logger.warning("CredentialSync: failed to read from source #{source}: #{inspect(reason)}")
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
    Application.get_env(:lattice, @delegate_config, [])
    |> Keyword.get(:credentials_source_sprite, nil)
  end

  defp credentials_target_sprites do
    Application.get_env(:lattice, @delegate_config, [])
    |> Keyword.get(:credentials_target_sprites, [])
  end
end
