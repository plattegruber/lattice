defmodule Lattice.Ambient.SpriteDelegate do
  @moduledoc """
  Delegates ambient questions to a sprite with full repo context.

  When the Claude classifier decides a question needs codebase awareness,
  this module hands off to a sprite that has the repo cloned and runs
  `claude -p` to generate a context-aware answer.

  Stateless — called from a Task spawned by the Responder.
  """

  require Logger

  alias Lattice.Capabilities.Sprites

  @doc """
  Handle a delegated event by running Claude Code on a sprite with repo context.

  Returns `{:ok, response_text}` or `{:error, reason}`.
  """
  @spec handle(event :: map(), thread_context :: [map()]) :: {:ok, String.t()} | {:error, term()}
  def handle(event, thread_context) do
    unless enabled?() do
      Logger.warning("SpriteDelegate: delegation disabled, falling back to error")
      {:error, :delegation_disabled}
    else
      with {:ok, sprite_name} <- ensure_sprite(),
           {:ok, response} <- run_claude_code(sprite_name, event, thread_context) do
        {:ok, response}
      end
    end
  end

  # ── Private: Sprite Lifecycle ────────────────────────────────────

  defp ensure_sprite do
    name = sprite_name()
    repo_url = repo_url()
    work_dir = work_dir()

    case Sprites.get_sprite(name) do
      {:ok, _sprite} ->
        Logger.info("SpriteDelegate: sprite #{name} exists, pulling latest")
        Sprites.exec(name, "cd #{work_dir} && git pull --ff-only 2>&1 || true")
        {:ok, name}

      {:error, not_found} when not_found == :not_found or elem(not_found, 0) == :not_found ->
        Logger.info("SpriteDelegate: creating sprite #{name}")

        with {:ok, _} <- Sprites.create_sprite(name, []),
             {:ok, _} <- Sprites.exec(name, "git clone #{repo_url} #{work_dir} 2>&1") do
          {:ok, name}
        else
          {:error, reason} = err ->
            Logger.error("SpriteDelegate: failed to set up sprite: #{inspect(reason)}")
            err
        end

      {:error, reason} = err ->
        Logger.error("SpriteDelegate: failed to get sprite #{name}: #{inspect(reason)}")
        err
    end
  end

  # ── Private: Claude Code Execution ───────────────────────────────

  defp run_claude_code(sprite_name, event, thread_context) do
    prompt = build_prompt(event, thread_context)
    work_dir = work_dir()
    timeout = delegation_timeout_ms()

    # Write prompt to a temp file on the sprite to avoid shell escaping issues
    write_cmd = "cat > /tmp/ambient_prompt.txt << 'LATTICE_PROMPT_EOF'\n#{prompt}\nLATTICE_PROMPT_EOF"

    with {:ok, _} <- Sprites.exec(sprite_name, write_cmd),
         {:ok, result} <-
           Sprites.exec(
             sprite_name,
             "cd #{work_dir} && timeout #{div(timeout, 1000)} claude -p \"$(cat /tmp/ambient_prompt.txt)\" --output-format text 2>&1"
           ) do
      output = result[:output] || result.output || ""

      if String.trim(output) == "" do
        {:error, :empty_response}
      else
        {:ok, String.trim(output)}
      end
    else
      {:error, reason} = err ->
        Logger.error("SpriteDelegate: claude execution failed: #{inspect(reason)}")
        err
    end
  end

  defp build_prompt(event, thread_context) do
    thread_text =
      thread_context
      |> Enum.map(fn c -> "**#{c[:user] || "unknown"}**: #{c[:body] || ""}" end)
      |> Enum.join("\n\n")

    thread_section =
      if thread_text != "" do
        """
        ## Thread context (previous messages):
        #{thread_text}

        """
      else
        ""
      end

    """
    You are helping answer a question about this codebase. You have full access to the repo.

    #{thread_section}## Current event:
    Event type: #{event[:type]}
    Author: #{event[:author]}
    Surface: #{event[:surface]}
    Number: #{event[:number]}

    Message:
    #{event[:body]}

    Instructions:
    - Answer helpfully and concisely based on the actual codebase
    - Reference specific files and line numbers when relevant
    - If you're unsure about something, say so rather than guessing
    - Keep your response focused and under 500 words
    """
  end

  # ── Private: Config ──────────────────────────────────────────────

  defp enabled? do
    config(:enabled, false)
  end

  defp sprite_name do
    config(:sprite_name, "lattice-ambient")
  end

  defp repo_url do
    Application.get_env(:lattice, :resources, [])
    |> Keyword.get(:github_repo, "")
    |> then(fn repo ->
      if String.starts_with?(repo, "http"), do: repo, else: "https://github.com/#{repo}.git"
    end)
  end

  defp work_dir do
    config(:work_dir, "/workspace/repo")
  end

  defp delegation_timeout_ms do
    config(:delegation_timeout_ms, 120_000)
  end

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
