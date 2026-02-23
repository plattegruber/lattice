# LatticeBundleHandoff Protocol (bundle-v1)

You are running inside a Lattice-managed sprite. When you finish implementing
changes, you MUST produce a structured handoff bundle so Lattice can push your
work and create a PR. **You never push to GitHub yourself.**

## Steps

1. **Ensure clean main checkout**
   ```bash
   git checkout main && git pull --ff-only
   ```

2. **Create your work branch**
   ```bash
   git checkout -b sprite/<slug>
   ```
   Use a descriptive slug derived from the issue (e.g., `sprite/fix-cache-key`).

3. **Make your changes**
   - Read CLAUDE.md first for project conventions
   - Implement the requested changes
   - Capture command output to `.lattice/out/` as needed

4. **Validate your work**
   ```bash
   mix format
   mix test 2>&1 | tee .lattice/out/test_output.txt
   ```

5. **Commit locally (never push)**
   ```bash
   git add -A
   git commit -m "sprite: <concise description>"
   ```

6. **Create the git bundle**
   ```bash
   git bundle create .lattice/out/change.bundle main..HEAD
   git bundle verify .lattice/out/change.bundle
   ```

7. **Create the diff patch**
   ```bash
   git diff main..HEAD > .lattice/out/diff.patch
   ```

8. **Write the proposal file**
   Write `.lattice/out/proposal.json` with this exact schema:
   ```json
   {
     "protocol_version": "bundle-v1",
     "status": "ready",
     "repo": "<owner/repo>",
     "base_branch": "main",
     "work_branch": "sprite/<slug>",
     "bundle_path": ".lattice/out/change.bundle",
     "patch_path": ".lattice/out/diff.patch",
     "summary": "Brief description of what was done",
     "pr": {
       "title": "Short PR title (under 70 chars)",
       "body": "Markdown body describing the changes",
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

   **Status values:**
   - `"ready"` — changes are committed and bundled
   - `"no_changes"` — nothing needed to be changed
   - `"blocked"` — cannot proceed (set `blocked_reason`)

9. **Signal completion**
   ```
   echo "HANDOFF_READY: .lattice/out/"
   ```
   This line MUST appear in your output. Lattice watches for it.

## Amendment Mode

When Lattice tells you to amend an existing PR, the prompt will say "Amendment Mode"
and you will already be checked out on the PR's head branch.

**Key differences from the normal flow:**

- **Do NOT** checkout main or create a new branch — you are already on the correct branch
- Make your changes, format, test, and commit as usual
- Create the bundle as `HEAD~1..HEAD` (just your new commit, not `main..HEAD`)
- Create the diff as `HEAD~1..HEAD`
- Set `work_branch` in `proposal.json` to the current branch name (the PR's head branch)
- Set `base_branch` to `"main"` as usual

Everything else (proposal schema, hard rules, signal completion) is the same.

## Hard Rules

- **NEVER** run `git push`
- **NEVER** call GitHub APIs (no `gh pr create`, no `curl` to api.github.com)
- **NEVER** edit git remotes
- **NEVER** expose or log tokens/secrets
- Always commit locally before creating the bundle
- Always verify the bundle with `git bundle verify`
- If you cannot complete the task, set status to `"blocked"` with a reason
- If no changes are needed, set status to `"no_changes"`
