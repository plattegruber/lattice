defmodule Mix.Tasks.Lattice.TestHandoff do
  @moduledoc """
  Local test of the bundle handoff protocol.

  Generates the implementation prompt, runs `claude -p` against the current
  repo (no sprite needed), then validates the resulting proposal.json.

  ## Usage

      # Dry run — just dump the prompt, don't run claude
      mix lattice.test_handoff --dry-run

      # Full run — actually invoke claude -p and validate the output
      mix lattice.test_handoff

      # Custom issue details
      mix lattice.test_handoff --number 123 --title "Fix the cache bug"
  """

  use Mix.Task

  alias Lattice.Ambient.Proposal
  alias Lattice.Ambient.ProposalPolicy

  @shortdoc "Test the bundle handoff protocol locally"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [dry_run: :boolean, number: :integer, title: :string],
        aliases: [n: :number, t: :title, d: :dry_run]
      )

    event = %{
      number: opts[:number] || 9999,
      title: opts[:title] || "Test handoff protocol locally",
      author: "local-test",
      body:
        "This is a local test of the bundle handoff protocol. Make a trivial change — add a comment to lib/lattice/ambient/proposal.ex explaining what the module does in one line, then follow the handoff protocol.",
      context_body: nil
    }

    repo = detect_repo()
    work_dir = File.cwd!()
    prompt = build_prompt(event, repo)

    if opts[:dry_run] do
      Mix.shell().info("=== DRY RUN — Prompt that would be sent ===\n")
      Mix.shell().info(prompt)
      Mix.shell().info("\n=== Prompt size: #{byte_size(prompt)} bytes ===")
    else
      run_full_test(prompt, work_dir, event)
    end
  end

  defp run_full_test(prompt, work_dir, event) do
    # Clean up any previous artifacts
    out_dir = Path.join(work_dir, ".lattice/out")
    File.rm_rf!(out_dir)
    File.mkdir_p!(out_dir)

    Mix.shell().info("Writing prompt to /tmp/handoff_test_prompt.txt...")
    File.write!("/tmp/handoff_test_prompt.txt", prompt)

    Mix.shell().info("Running claude -p (this may take a few minutes)...")
    Mix.shell().info("Work dir: #{work_dir}\n")

    {output, exit_code} =
      System.cmd(
        "sh",
        [
          "-c",
          "cd #{work_dir} && claude -p \"$(cat /tmp/handoff_test_prompt.txt)\" --output-format text 2>&1"
        ],
        env: [
          {"ANTHROPIC_API_KEY", System.get_env("ANTHROPIC_API_KEY") || ""},
          {"CLAUDECODE", nil}
        ],
        into: IO.stream(:stdio, :line)
      )

    Mix.shell().info("\n--- claude exited with code #{exit_code} ---\n")

    # Check for HANDOFF_READY signal
    output_str = if is_binary(output), do: output, else: ""

    if String.contains?(output_str, "HANDOFF_READY") do
      Mix.shell().info("[OK] HANDOFF_READY signal detected in output")
    else
      Mix.shell().info(
        "[WARN] HANDOFF_READY signal NOT found in streamed output (may be in proposal)"
      )
    end

    # Validate proposal.json
    proposal_path = Path.join(out_dir, "proposal.json")

    if File.exists?(proposal_path) do
      validate_proposal(proposal_path, work_dir, event)
    else
      Mix.shell().error("[FAIL] No proposal.json found at #{proposal_path}")
      Mix.shell().info("\nFiles in .lattice/out/:")

      case File.ls(out_dir) do
        {:ok, files} -> Enum.each(files, &Mix.shell().info("  #{&1}"))
        _ -> Mix.shell().info("  (empty or missing)")
      end
    end
  end

  defp validate_proposal(proposal_path, work_dir, _event) do
    Mix.shell().info("[OK] proposal.json found\n")
    json = File.read!(proposal_path)

    case Proposal.from_json(json) do
      {:ok, proposal} ->
        print_proposal_summary(proposal)
        verify_bundle_file(proposal, work_dir)
        run_policy_check(proposal, work_dir)
        cleanup_branches(proposal, work_dir)
        Mix.shell().info("\n=== HANDOFF TEST PASSED ===")

      {:error, reason} ->
        Mix.shell().error("[FAIL] Invalid proposal.json: #{inspect(reason)}")
        Mix.shell().info("\nRaw contents:")
        Mix.shell().info(json)
    end
  end

  defp print_proposal_summary(proposal) do
    Mix.shell().info("  protocol_version: #{proposal.protocol_version}")
    Mix.shell().info("  status:           #{proposal.status}")
    Mix.shell().info("  work_branch:      #{proposal.work_branch}")
    Mix.shell().info("  bundle_path:      #{proposal.bundle_path}")
    Mix.shell().info("  summary:          #{proposal.summary}")
    Mix.shell().info("  pr.title:         #{proposal.pr["title"]}")
    Mix.shell().info("  commands:         #{length(proposal.commands)}")
    Mix.shell().info("  flags:            #{inspect(proposal.flags)}")
    Mix.shell().info("")
  end

  defp verify_bundle_file(proposal, work_dir) do
    bundle_path = Path.join(work_dir, proposal.bundle_path)

    if File.exists?(bundle_path) do
      Mix.shell().info("[OK] Bundle file exists: #{proposal.bundle_path}")
      verify_bundle_integrity(bundle_path, work_dir)
    else
      Mix.shell().error("[FAIL] Bundle file missing: #{bundle_path}")
    end
  end

  defp verify_bundle_integrity(bundle_path, work_dir) do
    {verify_out, verify_code} =
      System.cmd("git", ["bundle", "verify", bundle_path],
        cd: work_dir,
        stderr_to_stdout: true
      )

    if verify_code == 0 do
      Mix.shell().info("[OK] git bundle verify passed")
    else
      Mix.shell().error("[FAIL] git bundle verify failed: #{verify_out}")
    end
  end

  defp run_policy_check(proposal, work_dir) do
    {diff_out, _} =
      System.cmd(
        "git",
        ["diff", "--name-only", "#{proposal.base_branch}..#{proposal.work_branch}"],
        cd: work_dir,
        stderr_to_stdout: true
      )

    diff_names = diff_out |> String.trim() |> String.split("\n", trim: true)
    Mix.shell().info("\nChanged files:")
    Enum.each(diff_names, &Mix.shell().info("  #{&1}"))

    case ProposalPolicy.check(proposal, diff_names) do
      {:ok, []} ->
        Mix.shell().info("\n[OK] Policy check passed — no warnings")

      {:ok, warnings} ->
        Mix.shell().info("\n[OK] Policy check passed with warnings:")
        Enum.each(warnings, &Mix.shell().info("  - #{&1}"))

      {:error, :policy_violation} ->
        Mix.shell().error("\n[FAIL] Policy violation — forbidden files in diff")
    end
  end

  defp cleanup_branches(proposal, work_dir) do
    Mix.shell().info("\n--- Cleaning up ---")
    System.cmd("git", ["checkout", "main"], cd: work_dir, stderr_to_stdout: true)

    System.cmd("git", ["branch", "-D", proposal.work_branch],
      cd: work_dir,
      stderr_to_stdout: true
    )

    Mix.shell().info("[OK] Reset to main, deleted #{proposal.work_branch}")
  end

  defp build_prompt(event, repo) do
    slug = slug_from(event[:title])

    """
    You are implementing changes for a GitHub issue in this codebase.
    Follow the LatticeBundleHandoff protocol exactly.

    ## Issue details:
    Issue number: ##{event[:number]}
    Title: #{event[:title]}
    Author: #{event[:author]}
    Repo: #{repo}

    Request:
    #{event[:body]}

    IMPORTANT: Before doing anything, verify you can see the codebase:
    1. Run `ls mix.exs CLAUDE.md` — if these files don't exist, STOP and say "ERROR: Cannot find repo files."
    2. Run `pwd` and include the result in your first line of output

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

  defp detect_repo do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} ->
        url
        |> String.trim()
        |> String.replace(~r{^https://github\.com/}, "")
        |> String.replace(~r{^git@github\.com:}, "")
        |> String.replace(~r{\.git$}, "")

      _ ->
        "owner/repo"
    end
  end

  defp slug_from(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> String.trim_trailing("-")
  end
end
