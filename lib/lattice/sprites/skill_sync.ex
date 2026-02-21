defmodule Lattice.Sprites.SkillSync do
  @moduledoc """
  Syncs sprite skills from `priv/sprite_skills/` to all managed sprites.

  On each deployment, Lattice discovers all sprites and pushes the latest
  skill files into `~/.claude/skills/soda-fountain/` on each sprite.
  The sync clears the target directory first to ensure a clean slate.
  """

  require Logger

  alias Lattice.Capabilities.Sprites
  alias Lattice.Sprites.FileWriter

  @skills_target "~/.claude/skills/soda-fountain"

  @doc """
  Sync all sprite skills to every discovered sprite.

  Returns a map of `%{sprite_name => :ok | {:error, reason}}`.
  """
  @spec sync_all() :: %{String.t() => :ok | {:error, term()}}
  def sync_all do
    case Sprites.list_sprites() do
      {:ok, sprites} ->
        skills = discover_skills()

        Logger.info(
          "SkillSync: syncing #{length(skills)} skill(s) to #{length(sprites)} sprite(s)"
        )

        results =
          Map.new(sprites, fn sprite ->
            name = sprite[:name] || sprite[:id]
            result = sync_sprite(name, skills)
            {name, result}
          end)

        ok_count = Enum.count(results, fn {_, v} -> v == :ok end)
        err_count = map_size(results) - ok_count
        Logger.info("SkillSync: complete — #{ok_count} ok, #{err_count} failed")

        results

      {:error, reason} ->
        Logger.warning("SkillSync: failed to list sprites: #{inspect(reason)}")
        %{}
    end
  end

  @doc """
  Sync all skills to a single sprite by name.
  """
  @spec sync_sprite(String.t()) :: :ok | {:error, term()}
  def sync_sprite(sprite_name) do
    sync_sprite(sprite_name, discover_skills())
  end

  @doc false
  @spec sync_sprite(String.t(), [{String.t(), String.t()}]) :: :ok | {:error, term()}
  def sync_sprite(sprite_name, skills) do
    with :ok <- clear_skills_dir(sprite_name),
         :ok <- create_skill_dirs(sprite_name, skills),
         :ok <- write_skill_files(sprite_name, skills),
         :ok <- verify_sync(sprite_name) do
      Logger.info("SkillSync: #{sprite_name} — synced #{length(skills)} file(s)")
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("SkillSync: #{sprite_name} — failed: #{inspect(reason)}")
        err
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp clear_skills_dir(sprite_name) do
    case Sprites.exec(sprite_name, "rm -rf #{@skills_target} && mkdir -p #{@skills_target}") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp create_skill_dirs(sprite_name, skills) do
    dirs =
      skills
      |> Enum.map(fn {rel_path, _content} -> Path.dirname(rel_path) end)
      |> Enum.uniq()

    mkdir_cmd =
      dirs
      |> Enum.map(fn dir -> "#{@skills_target}/#{dir}" end)
      |> Enum.join(" ")

    case Sprites.exec(sprite_name, "mkdir -p #{mkdir_cmd}") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp write_skill_files(sprite_name, skills) do
    Enum.reduce_while(skills, :ok, fn {rel_path, content}, :ok ->
      remote_path = "#{@skills_target}/#{rel_path}"

      case FileWriter.write_file(sprite_name, content, remote_path) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_sync(sprite_name) do
    case Sprites.exec(sprite_name, "ls -la #{@skills_target}/") do
      {:ok, %{output: output}} ->
        Logger.info("SkillSync: #{sprite_name} — verified: #{String.trim(output)}")
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Discover all skill files from `priv/sprite_skills/`.

  Returns a list of `{relative_path, content}` tuples.
  """
  @spec discover_skills() :: [{String.t(), String.t()}]
  def discover_skills do
    skills_dir = Application.app_dir(:lattice, "priv/sprite_skills")

    if File.dir?(skills_dir) do
      skills_dir
      |> walk_files()
      |> Enum.map(fn abs_path ->
        rel_path = Path.relative_to(abs_path, skills_dir)
        content = File.read!(abs_path)
        {rel_path, content}
      end)
    else
      Logger.warning("SkillSync: priv/sprite_skills not found at #{skills_dir}")
      []
    end
  end

  defp walk_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      if File.dir?(path) do
        walk_files(path)
      else
        [path]
      end
    end)
  end
end
