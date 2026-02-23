defmodule Lattice.Context.Delivery do
  @moduledoc """
  Writes a context Bundle to a sprite's filesystem.

  Follows the SkillSync pattern: clear → create → write → verify.
  Uses `FileWriter` for chunked base64 file transfer.
  """

  require Logger

  alias Lattice.Capabilities.Sprites
  alias Lattice.Context.Bundle
  alias Lattice.Sprites.FileWriter

  @context_dir "/workspace/.lattice/context"

  @doc """
  Deliver a Bundle to the named sprite.

  Clears the context directory, writes `manifest.json` and all file entries,
  then verifies the directory listing.
  """
  @spec deliver(String.t(), Bundle.t()) :: :ok | {:error, term()}
  def deliver(sprite_name, %Bundle{} = bundle) do
    with :ok <- clear_context_dir(sprite_name),
         :ok <- create_context_dirs(sprite_name, bundle),
         :ok <- write_manifest(sprite_name, bundle),
         :ok <- write_files(sprite_name, bundle),
         :ok <- verify_delivery(sprite_name) do
      Logger.info("Context: delivered #{length(bundle.files)} file(s) to #{sprite_name}")

      :ok
    else
      {:error, reason} = err ->
        Logger.warning("Context: delivery to #{sprite_name} failed: #{inspect(reason)}")
        err
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp clear_context_dir(sprite_name) do
    case Sprites.exec(sprite_name, "rm -rf #{@context_dir} && mkdir -p #{@context_dir}") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp create_context_dirs(sprite_name, bundle) do
    dirs =
      bundle.files
      |> Enum.map(fn %{path: path} -> Path.dirname(path) end)
      |> Enum.reject(&(&1 == "."))
      |> Enum.uniq()

    if dirs == [] do
      :ok
    else
      mkdir_cmd = Enum.map_join(dirs, " ", fn dir -> "#{@context_dir}/#{dir}" end)

      case Sprites.exec(sprite_name, "mkdir -p #{mkdir_cmd}") do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp write_manifest(sprite_name, bundle) do
    manifest_json = Bundle.to_manifest_json(bundle)
    FileWriter.write_file(sprite_name, manifest_json, "#{@context_dir}/manifest.json")
  end

  defp write_files(sprite_name, bundle) do
    Enum.reduce_while(bundle.files, :ok, fn %{path: path, content: content}, :ok ->
      remote_path = "#{@context_dir}/#{path}"

      case FileWriter.write_file(sprite_name, content, remote_path) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_delivery(sprite_name) do
    case Sprites.exec(sprite_name, "ls -la #{@context_dir}/") do
      {:ok, %{output: output}} ->
        Logger.info("Context: #{sprite_name} — verified: #{String.trim(output)}")
        :ok

      {:ok, _} ->
        :ok

      {:error, _} = err ->
        err
    end
  end
end
