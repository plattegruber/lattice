defmodule Lattice.Protocol.Resume do
  @moduledoc """
  Implements the protocol v1 resume flow: checkpoint restore → write context → exec.

  When a sprite emits a WAITING event with a checkpoint_id, it pauses. Lattice
  owns continuation. This module handles restoring the sprite to its checkpoint
  state, writing the resume payload, and executing the continuation command.

  ## Flow

  1. Restore checkpoint via Sprites API (sub-second)
  2. Write resume context to `/workspace/.lattice/resume.json`
  3. Exec the continuation command on the sprite
  """

  require Logger

  alias Lattice.Capabilities.Sprites
  alias Lattice.Sprites.FileWriter

  @resume_path "/workspace/.lattice/resume.json"

  @doc """
  Resume a sprite from a checkpoint with the given inputs.

  Returns `{:ok, session_pid}` for WebSocket-streamed execution, or
  `{:error, reason}` if any step fails.

  ## Options

  - `:command` — override the continuation command (default: uses the protocol skill)
  - `:work_item_id` — external work reference
  - `:context` — additional context map passed to the sprite
  """
  @spec resume(String.t(), String.t(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def resume(sprite_name, checkpoint_id, inputs, opts \\ []) do
    work_item_id = Keyword.get(opts, :work_item_id)
    context = Keyword.get(opts, :context, %{})

    command =
      Keyword.get(
        opts,
        :command,
        "claude -p 'Read /workspace/.lattice/resume.json and continue the workflow from the checkpoint.'"
      )

    Logger.info(
      "Resuming sprite #{sprite_name} from checkpoint #{checkpoint_id}"
    )

    with {:restore, {:ok, _}} <- {:restore, restore_checkpoint(sprite_name, checkpoint_id)},
         {:write, {:ok, _}} <-
           {:write, write_resume_context(sprite_name, checkpoint_id, inputs, work_item_id, context)},
         {:exec, {:ok, pid}} <- {:exec, Sprites.exec_ws(sprite_name, command)} do
      Logger.info("Sprite #{sprite_name} resumed, exec session started")
      {:ok, pid}
    else
      {:restore, {:error, reason}} ->
        Logger.error("Failed to restore checkpoint #{checkpoint_id}: #{inspect(reason)}")
        {:error, {:restore_failed, reason}}

      {:write, {:error, reason}} ->
        Logger.error("Failed to write resume context: #{inspect(reason)}")
        {:error, {:write_failed, reason}}

      {:exec, {:error, reason}} ->
        Logger.error("Failed to exec on #{sprite_name}: #{inspect(reason)}")
        {:error, {:exec_failed, reason}}
    end
  end

  @doc """
  Build the resume payload that gets written to the sprite filesystem.
  """
  @spec build_payload(String.t(), map(), String.t() | nil, map()) :: map()
  def build_payload(checkpoint_id, inputs, work_item_id, context \\ %{}) do
    %{
      work_item_id: work_item_id,
      checkpoint_id: checkpoint_id,
      inputs: inputs,
      context: context,
      resumed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp restore_checkpoint(sprite_name, checkpoint_id) do
    Sprites.restore_checkpoint(sprite_name, checkpoint_id)
  end

  defp write_resume_context(sprite_name, checkpoint_id, inputs, work_item_id, context) do
    payload = build_payload(checkpoint_id, inputs, work_item_id, context)

    case Jason.encode(payload) do
      {:ok, json} ->
        # Ensure directory exists, then write
        Sprites.exec(sprite_name, "mkdir -p /workspace/.lattice")
        FileWriter.write_file(sprite_name, json, @resume_path)

      {:error, reason} ->
        {:error, {:json_encode_failed, reason}}
    end
  end
end
