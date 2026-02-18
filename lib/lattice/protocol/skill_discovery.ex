defmodule Lattice.Protocol.SkillDiscovery do
  @moduledoc """
  Discovers and caches skill manifests from sprites.

  Discovery works by executing `cat /skills/*/skill.json` on the target sprite
  via the Sprites capability. Results are cached per-sprite in an ETS table
  with a configurable TTL (default 5 minutes).

  ## Cache Behaviour

  - Cold cache: triggers discovery via exec, caches the result, returns it.
  - Warm cache (within TTL): returns cached skills immediately.
  - Cache can be explicitly invalidated with `invalidate/1`.

  The ETS table is created on first use (lazy initialization) so it does not
  require a supervisor entry.
  """

  require Logger

  alias Lattice.Capabilities.Sprites
  alias Lattice.Protocol.SkillManifest

  @table_name :lattice_skill_cache
  @default_ttl_ms :timer.minutes(5)

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Discover available skills for the given sprite.

  If the cache is warm (within TTL), returns the cached manifests.
  Otherwise, executes discovery on the sprite and caches the result.

  Returns `{:ok, [%SkillManifest{}]}`.
  """
  @spec discover(String.t()) :: {:ok, [SkillManifest.t()]}
  def discover(sprite_name) when is_binary(sprite_name) do
    ensure_table()

    case read_cache(sprite_name) do
      {:ok, skills} ->
        {:ok, skills}

      :miss ->
        skills = discover_from_sprite(sprite_name)
        write_cache(sprite_name, skills)
        {:ok, skills}
    end
  end

  @doc """
  Invalidate the cached skills for a sprite.

  The next call to `discover/1` will re-execute discovery.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(sprite_name) when is_binary(sprite_name) do
    ensure_table()
    :ets.delete(@table_name, sprite_name)
    :ok
  end

  @doc """
  Get a single skill manifest by name for a sprite.

  Triggers discovery if the cache is cold.
  Returns `{:ok, manifest}` or `{:error, :not_found}`.
  """
  @spec get_skill(String.t(), String.t()) :: {:ok, SkillManifest.t()} | {:error, :not_found}
  def get_skill(sprite_name, skill_name) do
    {:ok, skills} = discover(sprite_name)

    case Enum.find(skills, &(&1.name == skill_name)) do
      nil -> {:error, :not_found}
      manifest -> {:ok, manifest}
    end
  end

  # ── Discovery ────────────────────────────────────────────────────────

  defp discover_from_sprite(sprite_name) do
    # Execute cat on all skill.json files. The command uses a glob that will
    # print each file separated by newlines. If no files match, the command
    # will return an error or empty output -- both handled gracefully.
    command = "cat /skills/*/skill.json 2>/dev/null || true"

    case Sprites.exec(sprite_name, command) do
      {:ok, %{output: output}} when is_binary(output) and output != "" ->
        parse_skill_manifests(output)

      {:ok, _} ->
        Logger.info("No skill manifests found for sprite #{sprite_name}")
        []

      {:error, reason} ->
        Logger.info("Could not discover skills for sprite #{sprite_name}: #{inspect(reason)}")

        []
    end
  end

  @doc false
  def parse_skill_manifests(output) do
    # The output may contain multiple JSON objects concatenated together.
    # We split on `}{` boundaries and try to parse each one.
    output
    |> split_json_objects()
    |> Enum.flat_map(fn json_str ->
      case Jason.decode(json_str) do
        {:ok, map} ->
          case SkillManifest.from_map(map) do
            {:ok, manifest} ->
              [manifest]

            {:error, reason} ->
              Logger.warning("Invalid skill manifest: #{reason}")
              []
          end

        {:error, _} ->
          Logger.warning("Failed to parse skill JSON: #{String.slice(json_str, 0, 100)}")
          []
      end
    end)
  end

  # Split concatenated JSON objects. Handles both cases:
  # 1. Newline-separated JSON objects
  # 2. Directly concatenated objects like `}{`
  defp split_json_objects(output) do
    output
    |> String.trim()
    |> String.split(~r/\}\s*\{/, include_captures: false)
    |> then(fn
      [single] ->
        [single]

      parts ->
        parts
        |> Enum.with_index()
        |> Enum.map(fn
          {part, 0} -> part <> "}"
          {part, idx} when idx == length(parts) - 1 -> "{" <> part
          {part, _} -> "{" <> part <> "}"
        end)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # ── ETS Cache ────────────────────────────────────────────────────────

  defp ensure_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError ->
      # Table already exists (race condition between whereis and new)
      :ok
  end

  defp read_cache(sprite_name) do
    case :ets.lookup(@table_name, sprite_name) do
      [{^sprite_name, skills, cached_at}] ->
        if System.monotonic_time(:millisecond) - cached_at < ttl_ms() do
          {:ok, skills}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  defp write_cache(sprite_name, skills) do
    :ets.insert(@table_name, {sprite_name, skills, System.monotonic_time(:millisecond)})
  end

  defp ttl_ms do
    Application.get_env(:lattice, :skill_cache_ttl_ms, @default_ttl_ms)
  end
end
