defmodule Lattice.Ambient.SpriteDelegate do
  @moduledoc """
  Delegates ambient questions to a sprite with full repo context.

  When the Claude classifier decides a question needs codebase awareness,
  this module hands off to a sprite that has the repo cloned and runs
  `claude -p` to generate a context-aware answer.

  Stateless — called from a Task spawned by the Responder.

  ## Implementation Flow (Bundle Handoff Protocol)

  When the classifier returns `:implement`, `handle_implementation/2` is called:

  1. Ensure the sprite exists (create or git pull)
  2. Prepare workspace (clean main, clear artifacts)
  3. Run `claude -p` with handoff protocol instructions
  4. Read `.lattice/out/proposal.json` from the sprite
  5. Validate proposal against policy checks
  6. Verify the git bundle
  7. Push bundle to GitHub using App token (sprite never sees the token)
  8. Return `{:ok, %{branch, proposal, warnings}}` for the Responder to create the PR
  """

  require Logger

  alias Lattice.Ambient.Proposal
  alias Lattice.Ambient.ProposalPolicy
  alias Lattice.Capabilities.GitHub
  alias Lattice.Capabilities.GitHub.AppAuth
  alias Lattice.Capabilities.Sprites
  alias Lattice.Sprites.CredentialSync
  alias Lattice.Sprites.ExecSession
  alias Lattice.Sprites.FileWriter

  @max_retries 2
  @retry_delay_ms 3_000

  @doc """
  Classify a GitHub event by running a lightweight `claude -p` on the ambient sprite.

  Used as a fallback when no Anthropic API key is configured, routing classification
  through the Pro account via OAuth credentials on the sprite.

  Returns `{:ok, decision, nil}` or `{:error, reason}`.
  """
  @spec classify(event :: map(), thread_context :: [map()]) ::
          {:ok, :implement | :delegate | :react | :ignore, nil} | {:error, term()}
  def classify(event, thread_context) do
    if enabled?() do
      with {:ok, sprite_name} <- ensure_sprite(),
           :ok <- sync_claude_credentials(sprite_name) do
        run_classification(sprite_name, event, thread_context)
      else
        _ -> {:ok, :ignore, nil}
      end
    else
      {:ok, :ignore, nil}
    end
  end

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
  Handle an implementation request using the bundle handoff protocol.

  The sprite makes changes and produces a structured proposal. Lattice validates
  the proposal and handles all GitHub operations (push, PR creation).

  Returns `{:ok, %{branch: String.t(), proposal: Proposal.t(), warnings: [String.t()]}}`
  on success, or `{:error, reason}` on failure.
  """
  @spec handle_implementation(event :: map(), thread_context :: [map()]) ::
          {:ok, %{branch: String.t(), proposal: Proposal.t(), warnings: [String.t()]}}
          | {:error, term()}
  def handle_implementation(event, thread_context) do
    if enabled?() do
      with {:ok, sprite_name} <- ensure_sprite(),
           {:ok, mode} <- detect_mode(event),
           :ok <- prepare_workspace(sprite_name, mode),
           :ok <- run_implementation(sprite_name, event, thread_context, mode),
           {:ok, proposal} <- read_proposal(sprite_name),
           {:ok, proposal, warnings} <- validate_proposal(proposal, sprite_name),
           :ok <- verify_and_push(sprite_name, proposal, mode) do
        {:ok, build_result(mode, proposal, warnings)}
      end
    else
      Logger.warning("SpriteDelegate: delegation disabled, cannot implement")
      {:error, :delegation_disabled}
    end
  end

  # ── Private: Mode Detection ──────────────────────────────────────

  defp detect_mode(%{is_pull_request: true, number: number}) when not is_nil(number) do
    case GitHub.get_pull_request(number) do
      {:ok, pr} ->
        # The GitHub capability already extracts head.ref into a flat string
        head_branch = pr[:head] || pr["head"]

        if is_binary(head_branch) and head_branch != "" do
          Logger.info(
            "SpriteDelegate: detected amendment mode for PR ##{number}, branch=#{head_branch}"
          )

          {:ok, {:amend_pr, number, head_branch}}
        else
          Logger.warning(
            "SpriteDelegate: PR ##{number} has no head ref, falling back to new PR mode"
          )

          {:ok, {:new_pr, build_branch_name(%{number: number})}}
        end

      {:error, reason} ->
        Logger.warning(
          "SpriteDelegate: failed to fetch PR ##{number}: #{inspect(reason)}, falling back to new PR"
        )

        {:ok, {:new_pr, build_branch_name(%{number: number})}}
    end
  end

  defp detect_mode(event) do
    {:ok, {:new_pr, build_branch_name(event)}}
  end

  # ── Private: Implementation Helpers ────────────────────────────────

  defp prepare_workspace(sprite_name, {:new_pr, _}) do
    work_dir = work_dir()

    # Force-clean the workspace: discard local changes, switch to main, pull latest.
    # Previous runs may leave the sprite on a work branch with dirty state.
    with {:ok, _} <-
           exec_with_retry(
             sprite_name,
             "cd #{work_dir} && git checkout -f main && git clean -fd && git pull --ff-only 2>&1 || true"
           ),
         {:ok, _} <-
           exec_with_retry(
             sprite_name,
             "cd #{work_dir} && rm -rf .lattice/out && mkdir -p .lattice/out"
           ) do
      :ok
    end
  end

  defp prepare_workspace(sprite_name, {:amend_pr, _pr_number, head_branch}) do
    work_dir = work_dir()

    # Fetch latest, checkout the PR's head branch, and pull it.
    with {:ok, _} <-
           exec_with_retry(
             sprite_name,
             "cd #{work_dir} && git fetch origin && git checkout -f #{head_branch} && git pull origin #{head_branch} 2>&1 || true"
           ),
         {:ok, _} <-
           exec_with_retry(
             sprite_name,
             "cd #{work_dir} && rm -rf .lattice/out && mkdir -p .lattice/out"
           ) do
      :ok
    end
  end

  defp run_implementation(sprite_name, event, thread_context, mode) do
    prompt = build_implementation_prompt(event, thread_context, mode)
    work_dir = work_dir()

    Logger.info(
      "SpriteDelegate: run_implementation work_dir=#{work_dir} prompt_size=#{byte_size(prompt)}"
    )

    # Sanity check: verify the repo directory exists
    sanity_cmd =
      "ls #{work_dir}/mix.exs #{work_dir}/CLAUDE.md 2>&1 && pwd && echo '--- SANITY OK ---'"

    exec_with_retry(sprite_name, sanity_cmd)

    with :ok <- sync_claude_credentials(sprite_name),
         :ok <- FileWriter.write_file(sprite_name, prompt, "/tmp/implement_prompt.txt") do
      claude_cmd =
        "cd #{work_dir} && #{claude_env_prefix()}claude -p \"$(cat /tmp/implement_prompt.txt)\" --model claude-opus-4-6 --output-format text 2>&1"

      Logger.info("SpriteDelegate: launching claude -p (implement)")

      case run_streaming_exec(sprite_name, claude_cmd) do
        {:ok, %{exit_code: 0}} ->
          :ok

        {:ok, %{exit_code: code, output: output}} ->
          Logger.warning(
            "SpriteDelegate: claude exited with code #{code}: #{String.slice(output, -500, 500)}"
          )

          # Still try to read proposal — claude might have produced one
          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  defp read_proposal(sprite_name) do
    work_dir = work_dir()

    case Sprites.exec(sprite_name, "cat #{work_dir}/.lattice/out/proposal.json 2>/dev/null") do
      {:ok, %{output: output, exit_code: 0}} when output != "" ->
        case Proposal.from_json(String.trim(output)) do
          {:ok, %Proposal{status: "no_changes"}} ->
            {:error, :no_changes}

          {:ok, %Proposal{status: "blocked", blocked_reason: reason}} ->
            {:error, {:blocked, reason}}

          {:ok, proposal} ->
            {:ok, proposal}

          {:error, reason} ->
            Logger.warning("SpriteDelegate: invalid proposal.json: #{inspect(reason)}")
            {:error, :invalid_proposal}
        end

      {:ok, %{exit_code: code}} ->
        Logger.warning("SpriteDelegate: no proposal.json found (exit=#{code})")
        {:error, :no_proposal}

      {:error, _} = err ->
        err
    end
  end

  defp validate_proposal(%Proposal{} = proposal, sprite_name) do
    work_dir = work_dir()

    case Sprites.exec(
           sprite_name,
           "cd #{work_dir} && git diff --name-only #{proposal.base_branch}..#{proposal.work_branch} 2>&1"
         ) do
      {:ok, %{output: output, exit_code: 0}} ->
        file_list =
          output
          |> String.trim()
          |> String.split("\n", trim: true)

        case ProposalPolicy.check(proposal, file_list) do
          {:ok, warnings} -> {:ok, proposal, warnings}
          {:error, _} = err -> err
        end

      {:ok, %{output: output}} ->
        Logger.warning("SpriteDelegate: git diff --name-only failed: #{output}")
        {:ok, proposal, []}

      {:error, _} = err ->
        err
    end
  end

  defp verify_and_push(sprite_name, proposal, {:new_pr, branch_name}) do
    with :ok <- verify_bundle(sprite_name, proposal) do
      push_bundle(sprite_name, branch_name, proposal)
    end
  end

  defp verify_and_push(sprite_name, _proposal, {:amend_pr, _pr_number, head_branch}) do
    # For amendments, the sprite committed directly on the PR branch.
    # Push the branch with --force-with-lease (safe force push).
    push_branch(sprite_name, head_branch)
  end

  defp verify_bundle(sprite_name, proposal) do
    work_dir = work_dir()

    case Sprites.exec(
           sprite_name,
           "cd #{work_dir} && git bundle verify #{proposal.bundle_path} 2>&1"
         ) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, _} -> {:error, :bundle_invalid}
      {:error, _} = err -> err
    end
  end

  defp push_bundle(sprite_name, branch_name, proposal) do
    work_dir = work_dir()
    token = github_app_token()
    repo = github_repo()

    # Fetch bundle into a local branch.
    # Bundles created with `git bundle create file main..HEAD` store a HEAD ref,
    # not the branch name ref. Use HEAD as the source ref.
    fetch_cmd =
      "cd #{work_dir} && git fetch #{proposal.bundle_path} HEAD:refs/heads/#{branch_name} 2>&1"

    # Set the push URL with the token (avoids logging it), then push.
    set_url_cmd =
      "cd #{work_dir} && git remote set-url origin " <>
        "https://x-access-token:#{token}@github.com/#{repo}.git 2>&1"

    push_cmd = "cd #{work_dir} && git push origin #{branch_name} 2>&1"

    with :ok <- exec_git(sprite_name, fetch_cmd, "bundle fetch"),
         :ok <- exec_git_quiet(sprite_name, set_url_cmd, "set push url") do
      exec_git(sprite_name, push_cmd, "push")
    end
  end

  defp push_branch(sprite_name, head_branch) do
    work_dir = work_dir()
    token = github_app_token()
    repo = github_repo()

    # Set the push URL with the token (avoids logging it in the command),
    # then push the branch as a fast-forward.
    set_url_cmd =
      "cd #{work_dir} && git remote set-url origin " <>
        "https://x-access-token:#{token}@github.com/#{repo}.git 2>&1"

    push_cmd = "cd #{work_dir} && git push origin #{head_branch} 2>&1"

    with :ok <- exec_git_quiet(sprite_name, set_url_cmd, "set push url") do
      exec_git(sprite_name, push_cmd, "push amendment")
    end
  end

  defp build_result({:new_pr, branch_name}, proposal, warnings) do
    %{branch: branch_name, proposal: proposal, warnings: warnings}
  end

  defp build_result({:amend_pr, pr_number, head_branch}, proposal, warnings) do
    %{branch: head_branch, proposal: proposal, warnings: warnings, amendment: pr_number}
  end

  # Execute a git command and validate success via both exit code and output.
  # The Sprites SDK may report exit_code 0 on failure (WebSocket race condition),
  # so we also check output for git error indicators.
  defp exec_git(sprite_name, command, label) do
    case exec_with_retry(sprite_name, command) do
      {:ok, %{output: output, exit_code: code}} ->
        if code != 0 or git_error?(output) do
          Logger.error(
            "SpriteDelegate: git #{label} failed (exit=#{code}): #{String.slice(output, 0, 500)}"
          )

          {:error, {:git_failed, label, output}}
        else
          :ok
        end

      {:ok, _} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  # Like exec_git but suppresses command logging (for commands containing tokens).
  defp exec_git_quiet(sprite_name, command, label) do
    case Sprites.exec(sprite_name, command) do
      {:ok, %{output: output, exit_code: code}} ->
        if code != 0 or git_error?(output) do
          Logger.error("SpriteDelegate: git #{label} failed (exit=#{code})")
          {:error, {:git_failed, label, output}}
        else
          :ok
        end

      {:ok, _} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp git_error?(output) do
    String.contains?(output, "fatal:") or
      String.contains?(output, "error: src refspec") or
      String.contains?(output, "error: failed to push")
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

  defp build_implementation_prompt(event, thread_context, mode) do
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

    repo = github_repo()
    preamble = build_prompt_preamble(event, thread_section, context_section, repo)
    protocol = build_prompt_protocol(event, mode, repo)

    """
    #{preamble}
    #{protocol}
    """
  end

  defp build_prompt_preamble(event, thread_section, context_section, repo) do
    """
    You are implementing changes for a GitHub issue/PR in this codebase.
    Follow the LatticeBundleHandoff protocol exactly.

    #{thread_section}## Details:
    Number: ##{event[:number]}
    Title: #{event[:title]}
    Author: #{event[:author]}
    Repo: #{repo}

    #{context_section}Request:
    #{event[:body]}

    IMPORTANT: Before doing anything, verify you can see the codebase:
    1. Run `ls mix.exs CLAUDE.md` — if these files don't exist, STOP and say "ERROR: Cannot find repo files."
    2. Run `pwd` and include the result in your first line of output
    """
  end

  defp build_prompt_protocol(event, {:new_pr, _}, repo) do
    slug = slug_from_event(event)

    """
    ## LatticeBundleHandoff Protocol (bundle-v1)

    You MUST follow these steps exactly:

    1. Read CLAUDE.md first to understand project conventions
    2. Ensure you are on a clean `main`:
       ```
       git checkout main && git pull --ff-only
       ```
    3. Create a work branch:
       ```
       git checkout -b sprite/#{slug}
       ```
    4. Implement the requested changes following existing patterns
    5. Run validation:
       ```
       mix format
       mix test 2>&1 | tee .lattice/out/test_output.txt
       ```
    6. Commit locally:
       ```
       git add -A
       git commit -m "sprite: <concise description of changes>"
       ```
    7. Create the bundle and patch:
       ```
       mkdir -p .lattice/out
       git bundle create .lattice/out/change.bundle main..HEAD
       git bundle verify .lattice/out/change.bundle
       git diff main..HEAD > .lattice/out/diff.patch
       ```
    8. Write `.lattice/out/proposal.json` with this exact schema:
       ```json
       {
         "protocol_version": "bundle-v1",
         "status": "ready",
         "repo": "#{repo}",
         "base_branch": "main",
         "work_branch": "sprite/#{slug}",
         "bundle_path": ".lattice/out/change.bundle",
         "patch_path": ".lattice/out/diff.patch",
         "summary": "<brief description>",
         "pr": {
           "title": "<short PR title under 70 chars>",
           "body": "<markdown PR body>",
           "labels": ["lattice:ambient"],
           "review_notes": []
         },
         "commands": [
           {"cmd": "mix format", "exit": 0},
           {"cmd": "mix test", "exit": 0}
         ],
         "flags": {
           "touches_migrations": false,
           "touches_deps": false,
           "touches_auth": false,
           "touches_secrets": false
         }
       }
       ```
       Set `status` to `"no_changes"` if nothing needed changing.
       Set `status` to `"blocked"` with `blocked_reason` if you cannot proceed.
    9. Print this exact line at the end:
       ```
       HANDOFF_READY: .lattice/out/
       ```

    ## Hard Rules
    - NEVER run `git push`
    - NEVER call GitHub APIs (no `gh pr create`, no `curl` to api.github.com)
    - NEVER edit git remotes
    - NEVER expose or log tokens/secrets
    - If you cannot find relevant files or the codebase seems empty, say so explicitly
    """
  end

  defp build_prompt_protocol(_event, {:amend_pr, pr_number, head_branch}, repo) do
    """
    ## LatticeBundleHandoff Protocol — Amendment Mode (bundle-v1)

    You are amending PR ##{pr_number} on branch `#{head_branch}`.
    **Do NOT checkout main or create a new branch.** You are already on the correct branch.

    You MUST follow these steps exactly:

    1. Read CLAUDE.md first to understand project conventions
    2. Verify you are on the correct branch:
       ```
       git branch --show-current   # Should show: #{head_branch}
       ```
    3. Implement the requested changes following existing patterns
    4. Run validation:
       ```
       mix format
       mix test 2>&1 | tee .lattice/out/test_output.txt
       ```
    5. Commit locally:
       ```
       git add -A
       git commit -m "sprite: <concise description of changes>"
       ```
    6. Create the bundle and patch (just your new commit):
       ```
       mkdir -p .lattice/out
       git bundle create .lattice/out/change.bundle HEAD~1..HEAD
       git bundle verify .lattice/out/change.bundle
       git diff HEAD~1..HEAD > .lattice/out/diff.patch
       ```
    7. Write `.lattice/out/proposal.json` with this exact schema:
       ```json
       {
         "protocol_version": "bundle-v1",
         "status": "ready",
         "repo": "#{repo}",
         "base_branch": "main",
         "work_branch": "#{head_branch}",
         "bundle_path": ".lattice/out/change.bundle",
         "patch_path": ".lattice/out/diff.patch",
         "summary": "<brief description>",
         "pr": {
           "title": "Amendment for PR ##{pr_number}",
           "body": "<markdown description of changes>",
           "labels": ["lattice:ambient"],
           "review_notes": []
         },
         "commands": [
           {"cmd": "mix format", "exit": 0},
           {"cmd": "mix test", "exit": 0}
         ],
         "flags": {
           "touches_migrations": false,
           "touches_deps": false,
           "touches_auth": false,
           "touches_secrets": false
         }
       }
       ```
       Set `status` to `"no_changes"` if nothing needed changing.
       Set `status` to `"blocked"` with `blocked_reason` if you cannot proceed.
    8. Print this exact line at the end:
       ```
       HANDOFF_READY: .lattice/out/
       ```

    ## Hard Rules
    - NEVER run `git push`
    - NEVER call GitHub APIs (no `gh pr create`, no `curl` to api.github.com)
    - NEVER edit git remotes
    - NEVER expose or log tokens/secrets
    - Do NOT checkout main or create a new branch — stay on `#{head_branch}`
    - If you cannot find relevant files or the codebase seems empty, say so explicitly
    """
  end

  defp slug_from_event(event) do
    title = event[:title] || "implementation"

    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> String.trim_trailing("-")
  end

  defp github_app_token do
    AppAuth.token() || System.get_env("GITHUB_TOKEN") || ""
  end

  defp github_repo do
    Application.get_env(:lattice, :resources, [])
    |> Keyword.get(:github_repo, "")
  end

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

    Logger.info(
      "SpriteDelegate: run_claude_code work_dir=#{work_dir} prompt_size=#{byte_size(prompt)}"
    )

    # Sanity check: verify the repo directory exists and has expected files
    sanity_cmd =
      "ls #{work_dir}/mix.exs #{work_dir}/CLAUDE.md 2>&1 && pwd && echo '--- SANITY OK ---'"

    exec_with_retry(sprite_name, sanity_cmd)

    with :ok <- sync_claude_credentials(sprite_name),
         :ok <- FileWriter.write_file(sprite_name, prompt, "/tmp/ambient_prompt.txt") do
      claude_cmd =
        "cd #{work_dir} && #{claude_env_prefix()}claude -p \"$(cat /tmp/ambient_prompt.txt)\" --model claude-opus-4-6 --output-format text 2>&1"

      Logger.info("SpriteDelegate: launching claude -p (delegate)")

      sprite_name
      |> run_streaming_exec(claude_cmd)
      |> process_claude_output()
    end
  end

  defp process_claude_output({:ok, %{output: output, exit_code: code}}) do
    Logger.info(
      "SpriteDelegate: claude finished exit_code=#{code} output_bytes=#{byte_size(output)}"
    )

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

  # ── Private: Classification via Sprite ────────────────────────────

  defp run_classification(sprite_name, event, thread_context) do
    prompt = build_classification_prompt(event, thread_context)

    Logger.info(
      "SpriteDelegate: running classification via sprite, prompt_size=#{byte_size(prompt)}"
    )

    case FileWriter.write_file(sprite_name, prompt, "/tmp/classify_prompt.txt") do
      :ok ->
        claude_cmd =
          "#{claude_env_prefix()}claude -p \"$(cat /tmp/classify_prompt.txt)\" --model claude-sonnet-4-20250514 --output-format json 2>&1"

        case exec_with_retry(sprite_name, claude_cmd) do
          {:ok, %{output: output, exit_code: 0}} ->
            parse_classification(output)

          {:ok, %{output: output, exit_code: code}} ->
            Logger.warning(
              "SpriteDelegate: classification exited #{code}: #{String.slice(output, -300, 300)}"
            )

            parse_classification(output)

          {:error, reason} ->
            Logger.error("SpriteDelegate: classification exec failed: #{inspect(reason)}")
            {:ok, :ignore, nil}
        end

      {:error, reason} ->
        Logger.error("SpriteDelegate: failed to write classification prompt: #{inspect(reason)}")
        {:ok, :ignore, nil}
    end
  end

  defp build_classification_prompt(event, thread_context) do
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

    event_text = """
    Event type: #{event[:type]}
    Author: #{event[:author]}
    Surface: #{event[:surface]}
    Number: #{event[:number]}

    Message body:
    #{event[:body]}
    """

    """
    You are Lattice, an AI coding agent control plane that monitors a GitHub repository. \
    You've received a new event from the repo you manage. Decide how to respond.

    Rules:
    1. If the message is an explicit request to implement, fix, build, or create code changes \
    (e.g., "implement this", "fix this", "build this feature", "make this change") → implement \
    (an agent will create a branch, make changes, and open a PR)
    2. If the message is a question, discussion, request for feedback, or anything substantive \
    → delegate (a repo-aware agent with full codebase access will answer)
    3. If the message is an acknowledgment, status update, or doesn't need a reply \
    (e.g., "sounds good", "done", "merged", "thanks") → react with thumbs-up
    4. If the event is noise (CI bot comments, auto-generated messages, dependency updates) → ignore

    IMPORTANT: Almost all substantive messages should be "delegate". The delegate agent has the \
    full repo cloned and can give much better answers than you can. Only use "react" or "ignore" \
    for messages that truly don't need a reply. Never use "respond" — always prefer "delegate" \
    for anything that warrants a thoughtful answer.

    #{thread_section}## New event:
    #{event_text}

    You MUST respond with EXACTLY this JSON format and nothing else:
    {"decision": "<one of: implement, delegate, react, ignore>"}
    """
  end

  defp parse_classification(output) do
    trimmed = String.trim(output)

    with {:ok, parsed} <- Jason.decode(trimmed),
         decision when is_binary(decision) <- Map.get(parsed, "decision") do
      case decision do
        "implement" ->
          {:ok, :implement, nil}

        "delegate" ->
          {:ok, :delegate, nil}

        "react" ->
          {:ok, :react, nil}

        "ignore" ->
          {:ok, :ignore, nil}

        other ->
          Logger.warning("SpriteDelegate: unknown classification decision: #{other}")
          {:ok, :ignore, nil}
      end
    else
      _ ->
        # Fallback: try to find JSON embedded in output
        case Regex.run(~r/\{[^}]*"decision"\s*:\s*"(\w+)"[^}]*\}/, trimmed) do
          [_, decision] ->
            parse_classification_decision(decision)

          nil ->
            Logger.warning(
              "SpriteDelegate: could not parse classification output: #{String.slice(trimmed, 0, 200)}"
            )

            {:ok, :ignore, nil}
        end
    end
  end

  defp parse_classification_decision("implement"), do: {:ok, :implement, nil}
  defp parse_classification_decision("delegate"), do: {:ok, :delegate, nil}
  defp parse_classification_decision("react"), do: {:ok, :react, nil}
  defp parse_classification_decision("ignore"), do: {:ok, :ignore, nil}
  defp parse_classification_decision(_), do: {:ok, :ignore, nil}

  # ── Private: Retry Logic ─────────────────────────────────────────

  defp exec_with_retry(sprite_name, command, attempt \\ 0) do
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

        Logger.info(
          "SpriteDelegate: stream complete exit_code=#{exit_code} total_bytes=#{byte_size(output)}"
        )

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

  defp credentials_source_sprite do
    config(:credentials_source_sprite, nil)
  end

  # Returns the env prefix for the claude command. When an API key is configured,
  # we inject it directly. Otherwise we rely on OAuth credentials on the sprite.
  defp claude_env_prefix do
    case anthropic_api_key() do
      key when key != "" and not is_nil(key) -> "ANTHROPIC_API_KEY=#{key} "
      _ -> ""
    end
  end

  # Copies ~/.claude/.credentials.json from the credentials source sprite to the
  # target sprite. This allows sprites to authenticate via OAuth (e.g. Claude Pro)
  # without an API key. Skipped when an API key is configured or when the source
  # is the target itself (or no source is configured).
  defp sync_claude_credentials(target_sprite) do
    source = credentials_source_sprite()
    api_key = anthropic_api_key()

    cond do
      api_key != "" and not is_nil(api_key) -> :ok
      is_nil(source) or source == "" -> :ok
      true -> CredentialSync.sync_one(source, target_sprite)
    end
  end

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
