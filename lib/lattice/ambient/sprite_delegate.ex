defmodule Lattice.Ambient.SpriteDelegate do
  @moduledoc """
  Delegates ambient questions to a sprite with full repo context.

  When the Claude classifier decides a question needs codebase awareness,
  this module hands off to a sprite that has the repo cloned and runs
  `claude -p` to generate a context-aware answer.

  Stateless — called from a Task spawned by the Responder.

  ## Implementation Flow

  When the classifier returns `:implement`, `handle_implementation/2` is called:

  1. Ensure the sprite exists (create or git pull)
  2. Check out a new branch: `lattice/issue-{N}-{slug}`
  3. Run `claude -p` in agentic mode to make code changes
  4. Commit and push the branch using a GitHub App token
  5. Return `{:ok, branch_name}` for the Responder to create the PR
  """

  require Logger

  alias Lattice.Capabilities.GitHub.AppAuth
  alias Lattice.Capabilities.Sprites
  alias Lattice.Sprites.ExecSession

  @max_retries 2
  @retry_delay_ms 3_000

  @doc """
  Handle a delegated event by running Claude Code on a sprite with repo context.

  Returns `{:ok, response_text}` or `{:error, reason}`.
  """
  @spec handle(event :: map(), thread_context :: [map()]) :: {:ok, String.t()} | {:error, term()}
  def handle(event, thread_context) do
    if enabled?() do
      with {:ok, sprite_name} <- ensure_sprite() do
        run_claude_code(sprite_name, event, thread_context)
      end
    else
      Logger.warning("SpriteDelegate: delegation disabled, falling back to error")
      {:error, :delegation_disabled}
    end
  end

  @doc """
  Handle an implementation request by creating a branch, running Claude Code
  in agentic mode, and pushing the result.

  Returns `{:ok, branch_name}` on success, `{:error, :no_changes}` if Claude
  made no modifications, or `{:error, reason}` on failure.
  """
  @spec handle_implementation(event :: map(), thread_context :: [map()]) ::
          {:ok, String.t()} | {:error, term()}
  def handle_implementation(event, thread_context) do
    if enabled?() do
      branch_name = build_branch_name(event)

      with {:ok, sprite_name} <- ensure_sprite(),
           :ok <- create_and_checkout_branch(sprite_name, branch_name),
           :ok <- run_implementation(sprite_name, event, thread_context),
           :ok <- commit_and_push(sprite_name, branch_name, event) do
        {:ok, branch_name}
      end
    else
      Logger.warning("SpriteDelegate: delegation disabled, cannot implement")
      {:error, :delegation_disabled}
    end
  end

  # ── Private: Implementation Helpers ────────────────────────────────

  defp create_and_checkout_branch(sprite_name, branch_name) do
    work_dir = work_dir()

    cmd =
      "cd #{work_dir} && git checkout main && git pull --ff-only 2>&1 && git checkout -b #{branch_name} 2>&1"

    case exec_with_retry(sprite_name, cmd) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp run_implementation(sprite_name, event, thread_context) do
    prompt = build_implementation_prompt(event, thread_context)
    work_dir = work_dir()

    Logger.info(
      "SpriteDelegate: run_implementation work_dir=#{work_dir} prompt_size=#{byte_size(prompt)}"
    )

    # Sanity check: verify the repo directory exists
    sanity_cmd = "ls #{work_dir}/mix.exs #{work_dir}/CLAUDE.md 2>&1 && pwd && echo '--- SANITY OK ---'"
    exec_with_retry(sprite_name, sanity_cmd)

    with {:ok, _} <- write_prompt_file(sprite_name, prompt, "/tmp/implement_prompt.txt") do
      claude_cmd =
        "cd #{work_dir} && ANTHROPIC_API_KEY=#{anthropic_api_key()} claude -p \"$(cat /tmp/implement_prompt.txt)\" --output-format text 2>&1"

      Logger.info("SpriteDelegate: launching claude -p (implement)")

      case run_streaming_exec(sprite_name, claude_cmd) do
        {:ok, %{exit_code: 0}} ->
          :ok

        {:ok, %{exit_code: code, output: output}} ->
          Logger.warning(
            "SpriteDelegate: claude exited with code #{code}: #{String.slice(output, -500, 500)}"
          )

          # Still try to commit — claude might have made partial changes
          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  defp commit_and_push(sprite_name, branch_name, event) do
    work_dir = work_dir()
    number = event[:number]

    with {:ok, _} <- exec_with_retry(sprite_name, "cd #{work_dir} && git add -A 2>&1"),
         :ok <- check_staged_changes(sprite_name, work_dir, number) do
      do_commit_and_push(sprite_name, work_dir, branch_name, event)
    end
  end

  defp check_staged_changes(sprite_name, work_dir, number) do
    case Sprites.exec(sprite_name, "cd #{work_dir} && git diff --cached --quiet") do
      {:ok, %{exit_code: 0}} ->
        Logger.warning("SpriteDelegate: no changes to commit for ##{number}")
        {:error, :no_changes}

      _ ->
        :ok
    end
  end

  defp do_commit_and_push(sprite_name, work_dir, branch_name, event) do
    number = event[:number]
    title = escape_single_quotes(event[:title] || "Issue ##{number}")
    commit_msg = "lattice: implement ##{number} - #{title}"

    commit_cmd =
      "cd #{work_dir} && git commit -m '#{escape_single_quotes(commit_msg)}' 2>&1"

    token = github_app_token()
    repo = github_repo()

    push_cmd =
      "cd #{work_dir} && git push https://x-access-token:#{token}@github.com/#{repo}.git #{branch_name} 2>&1"

    with {:ok, _} <- exec_with_retry(sprite_name, commit_cmd),
         {:ok, _} <- exec_with_retry(sprite_name, push_cmd) do
      :ok
    end
  end

  defp build_branch_name(event) do
    number = event[:number] || 0
    title = event[:title] || "implementation"

    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim_trailing("-")

    "lattice/issue-#{number}-#{slug}"
  end

  defp build_implementation_prompt(event, thread_context) do
    thread_text =
      Enum.map_join(thread_context, "\n\n", fn c ->
        "**#{c[:user] || "unknown"}**: #{c[:body] || ""}"
      end)

    thread_section =
      if thread_text != "" do
        """
        ## Thread context (previous messages):
        #{thread_text}

        """
      else
        ""
      end

    context_section =
      if event[:context_body] && event[:context_body] != "" do
        """
        ## Issue/PR description:
        #{event[:context_body]}

        """
      else
        ""
      end

    """
    You are implementing changes for a GitHub issue in this codebase.

    #{thread_section}## Issue details:
    Issue number: ##{event[:number]}
    Title: #{event[:title]}
    Author: #{event[:author]}

    #{context_section}Request:
    #{event[:body]}

    IMPORTANT: Before doing anything, verify you can see the codebase:
    1. Run `ls mix.exs CLAUDE.md` — if these files don't exist, STOP and say "ERROR: Cannot find repo files. pwd=$(pwd), ls=$(ls)"
    2. Run `pwd` and include the result in your first line of output

    Instructions:
    - Read CLAUDE.md first to understand project conventions
    - Start by understanding the issue: read the title, description, and any thread context above
    - Search the codebase for relevant code (grep for keywords from the issue title/description)
    - Implement the requested changes following existing patterns
    - Run `mix format` before finishing
    - Do NOT create a PR, push to remote, or run git operations — only modify files
    - Focus on a clean, minimal implementation that solves what was asked
    - If you cannot find relevant files or the codebase seems empty, say so explicitly — do NOT guess or make up file contents
    """
  end

  defp github_app_token do
    AppAuth.token() || System.get_env("GITHUB_TOKEN") || ""
  end

  defp github_repo do
    Application.get_env(:lattice, :resources, [])
    |> Keyword.get(:github_repo, "")
  end

  defp escape_single_quotes(str) when is_binary(str) do
    String.replace(str, "'", "'\\''")
  end

  defp escape_single_quotes(_), do: ""

  # ── Private: Sprite Lifecycle ────────────────────────────────────

  defp ensure_sprite do
    name = sprite_name()
    repo_url = repo_url()
    work_dir = work_dir()

    case Sprites.get_sprite(name) do
      {:ok, _sprite} ->
        Logger.info("SpriteDelegate: sprite #{name} exists, work_dir=#{work_dir}, pulling latest")
        exec_with_retry(name, "cd #{work_dir} && git pull --ff-only 2>&1 || true")
        {:ok, name}

      {:error, not_found} when not_found == :not_found or elem(not_found, 0) == :not_found ->
        Logger.info("SpriteDelegate: creating sprite #{name}")

        with {:ok, _} <- Sprites.create_sprite(name, []),
             {:ok, _} <- exec_with_retry(name, "git clone #{repo_url} #{work_dir} 2>&1") do
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

    Logger.info("SpriteDelegate: run_claude_code work_dir=#{work_dir} prompt_size=#{byte_size(prompt)}")

    # Sanity check: verify the repo directory exists and has expected files
    sanity_cmd = "ls #{work_dir}/mix.exs #{work_dir}/CLAUDE.md 2>&1 && pwd && echo '--- SANITY OK ---'"
    exec_with_retry(sprite_name, sanity_cmd)

    with {:ok, _} <- write_prompt_file(sprite_name, prompt, "/tmp/ambient_prompt.txt") do
      claude_cmd =
        "cd #{work_dir} && ANTHROPIC_API_KEY=#{anthropic_api_key()} claude -p \"$(cat /tmp/ambient_prompt.txt)\" --output-format text 2>&1"

      Logger.info("SpriteDelegate: launching claude -p (delegate)")

      sprite_name
      |> run_streaming_exec(claude_cmd)
      |> process_claude_output()
    end
  end

  defp process_claude_output({:ok, %{output: output, exit_code: code}}) do
    Logger.info("SpriteDelegate: claude finished exit_code=#{code} output_bytes=#{byte_size(output)}")

    # Log first and last 500 chars for debugging
    Logger.info("SpriteDelegate: claude output HEAD: #{String.slice(output, 0, 500)}")

    if byte_size(output) > 500 do
      Logger.info("SpriteDelegate: claude output TAIL: #{String.slice(output, -500, 500)}")
    end

    trimmed = String.trim(output)

    if trimmed == "", do: {:error, :empty_response}, else: {:ok, trimmed}
  end

  defp process_claude_output({:ok, %{output: output}}) do
    Logger.info("SpriteDelegate: claude returned #{byte_size(output)} bytes (no exit code)")
    trimmed = String.trim(output)

    if trimmed == "", do: {:error, :empty_response}, else: {:ok, trimmed}
  end

  defp process_claude_output({:error, reason} = err) do
    Logger.error("SpriteDelegate: claude execution failed: #{inspect(reason)}")
    err
  end

  # ── Private: Prompt File Writing ─────────────────────────────────

  defp write_prompt_file(sprite_name, prompt, path) do
    # Base64 encode to avoid any shell escaping issues with heredocs.
    # The prompt may contain backticks, quotes, $, etc. from GitHub content.
    encoded = Base.encode64(prompt)

    # Split into chunks to avoid hitting command-line length limits
    chunks = chunk_string(encoded, 50_000)

    # First chunk creates/overwrites the staging file, rest append
    [{first, :write} | rest] =
      [{hd(chunks), :write} | Enum.map(tl(chunks), &{&1, :append})]

    with {:ok, _} <-
           exec_with_retry(sprite_name, "printf '%s' '#{first}' > #{path}.b64"),
         {:ok, _} <- append_chunks(sprite_name, rest, path),
         {:ok, _} <- exec_with_retry(sprite_name, "base64 -d #{path}.b64 > #{path}") do
      {:ok, nil}
    end
  end

  defp append_chunks(_sprite_name, [], _path), do: {:ok, nil}

  defp append_chunks(sprite_name, [{chunk, :append} | rest], path) do
    case exec_with_retry(sprite_name, "printf '%s' '#{chunk}' >> #{path}.b64") do
      {:ok, _} -> append_chunks(sprite_name, rest, path)
      err -> err
    end
  end

  defp chunk_string(str, size) do
    str
    |> Stream.unfold(fn
      "" -> nil
      s -> String.split_at(s, size)
    end)
    |> Enum.to_list()
  end

  # ── Private: Retry Logic ─────────────────────────────────────────

  defp exec_with_retry(sprite_name, command, attempt \\ 0) do
    # Truncate command for logging (don't log huge b64 chunks)
    log_cmd = String.slice(command, 0, 200)
    Logger.info("SpriteDelegate: exec[#{attempt}] #{log_cmd}")

    case Sprites.exec(sprite_name, command) do
      {:ok, %{output: output, exit_code: code}} = success ->
        log_output = String.slice(output || "", 0, 500)
        Logger.info("SpriteDelegate: exec OK (exit=#{code}): #{log_output}")
        success

      {:ok, _} = success ->
        Logger.info("SpriteDelegate: exec OK (no structured output)")
        success

      {:error, reason} = err ->
        if attempt < @max_retries and retryable?(reason) do
          Logger.warning(
            "SpriteDelegate: exec failed (attempt #{attempt + 1}/#{@max_retries + 1}), " <>
              "retrying in #{@retry_delay_ms}ms: #{inspect(reason)}"
          )

          Process.sleep(@retry_delay_ms)
          exec_with_retry(sprite_name, command, attempt + 1)
        else
          Logger.error(
            "SpriteDelegate: exec failed permanently after #{attempt + 1} attempt(s): #{inspect(reason)}"
          )

          err
        end
    end
  end

  defp retryable?({:request_failed, _}), do: true
  defp retryable?(:timeout), do: true
  defp retryable?(:rate_limited), do: true
  defp retryable?(_), do: false

  # ── Private: Streaming Exec ─────────────────────────────────────

  defp run_streaming_exec(sprite_name, command) do
    idle_timeout = config(:exec_idle_timeout_ms, 1_800_000)

    case Sprites.exec_ws(sprite_name, command, idle_timeout: idle_timeout) do
      {:ok, session_pid} ->
        collect_streaming_output(session_pid)

      {:error, _} = err ->
        err
    end
  end

  defp collect_streaming_output(session_pid) do
    ref = Process.monitor(session_pid)
    {:ok, session_state} = ExecSession.get_state(session_pid)
    session_id = session_state.session_id
    topic = ExecSession.exec_topic(session_id)

    Phoenix.PubSub.subscribe(Lattice.PubSub, topic)
    result = collect_loop(ref, [])
    Phoenix.PubSub.unsubscribe(Lattice.PubSub, topic)
    Process.demonitor(ref, [:flush])
    result
  end

  defp collect_loop(ref, chunks) do
    idle_timeout = config(:exec_idle_timeout_ms, 1_800_000)

    receive do
      {:exec_output, %{stream: :exit, chunk: chunk}} ->
        exit_code = parse_exit_code(chunk)
        output = chunks |> Enum.reverse() |> Enum.join()
        Logger.info("SpriteDelegate: stream complete exit_code=#{exit_code} total_bytes=#{byte_size(output)}")
        {:ok, %{output: output, exit_code: exit_code}}

      {:exec_output, %{stream: stream, chunk: chunk}} when stream in [:stdout, :stderr] ->
        chunk_str = to_string(chunk)
        Logger.info("SpriteDelegate: [#{stream}] #{String.slice(chunk_str, 0, 200)}")
        collect_loop(ref, [chunk_str | chunks])

      {:exec_output, _other} ->
        collect_loop(ref, chunks)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        output = chunks |> Enum.reverse() |> Enum.join()
        {:ok, %{output: output, exit_code: 0}}
    after
      idle_timeout ->
        {:error, :idle_timeout}
    end
  end

  defp parse_exit_code(chunk) when is_binary(chunk) do
    case Regex.run(~r/code (\d+)/, chunk) do
      [_, code_str] -> String.to_integer(code_str)
      _ -> 1
    end
  end

  defp parse_exit_code(_), do: 1

  # ── Private: Prompt ──────────────────────────────────────────────

  defp build_prompt(event, thread_context) do
    thread_text =
      Enum.map_join(thread_context, "\n\n", fn c ->
        "**#{c[:user] || "unknown"}**: #{c[:body] || ""}"
      end)

    thread_section =
      if thread_text != "" do
        """
        ## Thread context (previous messages):
        #{thread_text}

        """
      else
        ""
      end

    context_section =
      if event[:context_body] && event[:context_body] != "" do
        """
        ## Issue/PR description:
        #{event[:context_body]}

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
    Title: #{event[:title]}

    #{context_section}Message:
    #{event[:body]}

    IMPORTANT: Before doing anything, verify you can see the codebase:
    1. Run `ls mix.exs CLAUDE.md` — if these files don't exist, STOP and say "ERROR: Cannot find repo files. pwd=$(pwd), ls=$(ls)"
    2. Run `pwd` and include the result in your first line of output

    Instructions:
    - Answer helpfully and concisely based on the actual codebase
    - Reference specific files and line numbers when relevant
    - If you're unsure about something, say so rather than guessing
    - If you cannot find relevant files or the codebase seems empty, say so explicitly — do NOT guess or make up file contents
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

  defp anthropic_api_key do
    Application.get_env(:lattice, Lattice.Ambient.Claude, [])
    |> Keyword.get(:api_key, "")
  end

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
