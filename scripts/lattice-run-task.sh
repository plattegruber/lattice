#!/usr/bin/env bash
# lattice-run-task.sh -- Reference implementation of the task script
#
# This is the standalone version of the inline script that
# Lattice.Intents.Executor.Task.build_script/1 generates.  It exists
# as documentation and for manual testing on a sprite.
#
# Usage:
#   REPO=plattegruber/webapp \
#   TASK_KIND=open_pr_trivial_change \
#   INSTRUCTIONS="Add a README file" \
#   BASE_BRANCH=main \
#   PR_TITLE="Add README" \
#   PR_BODY="Automated task: add a README" \
#     ./scripts/lattice-run-task.sh
#
# Environment variables:
#   REPO           - GitHub owner/repo (required)
#   TASK_KIND      - Short identifier for the task (required)
#   INSTRUCTIONS   - Text describing the change (required)
#   BASE_BRANCH    - Branch to base the work on (default: main)
#   PR_TITLE       - Title for the PR (default: "Task: $TASK_KIND")
#   PR_BODY        - Body for the PR (default: "Automated task: $TASK_KIND")
#   WORKSPACE      - Working directory (default: /workspace)
#
# Output contract:
#   On success, the last two lines of stdout are:
#     LATTICE_PR_URL=<url>
#     {"pr_url": "<url>"}
#
#   The executor parses stdout for a GitHub PR URL matching:
#     https://github.com/<owner>/<repo>/pull/<number>
#
#   Exit code 0 on success, non-zero on any failure.

set -euo pipefail

# ── Validate required inputs ─────────────────────────────────────────────

: "${REPO:?REPO is required (e.g. plattegruber/webapp)}"
: "${TASK_KIND:?TASK_KIND is required (e.g. open_pr_trivial_change)}"
: "${INSTRUCTIONS:?INSTRUCTIONS is required}"

BASE_BRANCH="${BASE_BRANCH:-main}"
PR_TITLE="${PR_TITLE:-Task: ${TASK_KIND}}"
PR_BODY="${PR_BODY:-Automated task: ${TASK_KIND}}"
WORKSPACE="${WORKSPACE:-/workspace}"
BRANCH_NAME="lattice/${TASK_KIND}-$(date +%s)"

# ── Clone and branch ─────────────────────────────────────────────────────

cd "${WORKSPACE}"

# Clean up any previous run
rm -rf task-repo

git clone "https://github.com/${REPO}.git" task-repo
cd task-repo
git checkout -b "${BRANCH_NAME}" "origin/${BASE_BRANCH}"

# ── Apply the change ─────────────────────────────────────────────────────

# Write the instructions to a marker file.  A real task would do more here
# (e.g. invoke Claude Code with these instructions).  The trivial version
# just records the instructions so there is something to commit.
cat > .lattice-task <<'LATTICE_EOF'
${INSTRUCTIONS}
LATTICE_EOF

# For the standalone script we also write the actual expanded value so the
# commit has meaningful content.
printf '%s\n' "${INSTRUCTIONS}" > .lattice-task

# ── Commit and push ──────────────────────────────────────────────────────

git add -A
git commit -m "${PR_TITLE}"
git push origin "${BRANCH_NAME}"

# ── Open PR ──────────────────────────────────────────────────────────────

PR_URL=$(gh pr create \
  --repo "${REPO}" \
  --title "${PR_TITLE}" \
  --body "${PR_BODY}" \
  --base "${BASE_BRANCH}" \
  --head "${BRANCH_NAME}" 2>&1 \
  | grep -oE 'https://github\.com/[^[:space:]]+/pull/[0-9]+' \
  | head -1)

if [ -z "${PR_URL}" ]; then
  echo "ERROR: gh pr create did not return a PR URL" >&2
  exit 1
fi

# ── Output contract ──────────────────────────────────────────────────────

echo "LATTICE_PR_URL=${PR_URL}"
echo "{\"pr_url\": \"${PR_URL}\"}"
