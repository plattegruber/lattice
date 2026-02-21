defmodule Lattice.Sprites.FileWriter do
  @moduledoc """
  Writes files to remote sprites via base64-encoded chunked exec commands.

  Large files are split into chunks, base64-encoded, transmitted via exec,
  then decoded on the sprite. This avoids shell escaping issues with arbitrary
  file content.
  """

  require Logger

  alias Lattice.Capabilities.Sprites

  @chunk_size 50_000
  @max_retries 2
  @retry_delay_ms 3_000

  @doc """
  Write `content` to `remote_path` on the given sprite.

  The content is base64-encoded, split into chunks, written to a `.b64`
  temp file on the sprite, then decoded to the final path.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec write_file(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_file(sprite_name, content, remote_path) do
    encoded = Base.encode64(content)
    chunks = chunk_string(encoded, @chunk_size)

    with :ok <- write_first_chunk(sprite_name, hd(chunks), remote_path),
         :ok <- append_remaining_chunks(sprite_name, tl(chunks), remote_path),
         :ok <- decode_file(sprite_name, remote_path) do
      :ok
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp write_first_chunk(sprite_name, chunk, remote_path) do
    case exec_with_retry(sprite_name, "printf '%s' '#{chunk}' > #{remote_path}.b64") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp append_remaining_chunks(_sprite_name, [], _remote_path), do: :ok

  defp append_remaining_chunks(sprite_name, [chunk | rest], remote_path) do
    case exec_with_retry(sprite_name, "printf '%s' '#{chunk}' >> #{remote_path}.b64") do
      {:ok, _} -> append_remaining_chunks(sprite_name, rest, remote_path)
      err -> err
    end
  end

  defp decode_file(sprite_name, remote_path) do
    case exec_with_retry(sprite_name, "base64 -d #{remote_path}.b64 > #{remote_path}") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp exec_with_retry(sprite_name, command, attempt \\ 0) do
    case Sprites.exec(sprite_name, command) do
      {:ok, _} = success ->
        success

      {:error, reason} = err ->
        if attempt < @max_retries and retryable?(reason) do
          Logger.warning(
            "FileWriter: exec failed (attempt #{attempt + 1}/#{@max_retries + 1}), " <>
              "retrying in #{@retry_delay_ms}ms: #{inspect(reason)}"
          )

          Process.sleep(@retry_delay_ms)
          exec_with_retry(sprite_name, command, attempt + 1)
        else
          err
        end
    end
  end

  defp retryable?({:request_failed, _}), do: true
  defp retryable?(:timeout), do: true
  defp retryable?(:rate_limited), do: true
  defp retryable?(_), do: false

  @doc false
  def chunk_string(str, size) do
    str
    |> Stream.unfold(fn
      "" -> nil
      s -> String.split_at(s, size)
    end)
    |> Enum.to_list()
  end
end
