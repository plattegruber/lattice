# Lattice Context Gathering Specification (v1)

> **Status:** Stable v1

This specification defines how Lattice assembles GitHub context into a structured
file bundle on a Sprite's filesystem. It governs what context is gathered, how it
is rendered, and where it is delivered.

It explicitly **does not** define:

- Sprite ↔ Lattice communication (see Protocol v1)
- How sprites consume context (see Context Skill)
- On-demand context refresh (future work)

---

## Design Principles

1. **Context is pre-gathered.** Lattice fetches and renders context before the sprite starts working, so the sprite has immediate access without API calls.
2. **Context is structured files.** Each piece of context (trigger, thread, diff stats, reviews, linked items) is a separate markdown file with a JSON manifest.
3. **Expansion is bounded.** Cross-references (`#NNN`) are expanded to depth=1 with a configurable budget (default 5) to prevent unbounded API calls.
4. **Rendering is pure.** Markdown rendering functions have no side effects and no GitHub API calls. Gathering and rendering are cleanly separated.
5. **Delivery follows SkillSync patterns.** Context is written to sprites using the same FileWriter infrastructure as skill sync.

---

## Inputs

Context gathering is triggered by a `Trigger` struct containing:

| Field | Required | Description |
|---|---|---|
| `type` | yes | `:issue` or `:pull_request` |
| `number` | yes | GitHub issue/PR number |
| `repo` | yes | Repository in `"owner/name"` format |
| `title` | no | Issue/PR title |
| `body` | no | Issue/PR body text |
| `author` | no | Author login |
| `labels` | no | List of label names |
| `head_branch` | no | PR head branch (PRs only). Also used to detect amendment context for PR-triggered implementations. |
| `base_branch` | no | PR base branch (PRs only) |
| `thread_context` | no | Pre-fetched comments (avoids re-fetch) |

---

## Filesystem Contract

Context is delivered to:

```
/workspace/.lattice/context/
├── manifest.json          # Bundle metadata + file index
├── trigger.md             # Primary issue/PR with body and metadata
├── thread.md              # Chronological comment thread
├── diff_stats.md          # PR file changes table (PRs only)
├── reviews.md             # Review verdicts + inline comments (PRs only)
└── linked/
    ├── issue_42.md        # Expanded cross-reference
    └── issue_108.md       # Expanded cross-reference
```

### manifest.json

```json
{
  "version": "v1",
  "trigger_type": "pull_request",
  "trigger_number": 123,
  "repo": "owner/name",
  "title": "Add context gathering",
  "gathered_at": "2026-02-23T12:00:00Z",
  "files": [
    {"path": "trigger.md", "kind": "trigger"},
    {"path": "thread.md", "kind": "thread"},
    {"path": "diff_stats.md", "kind": "diff_stats"},
    {"path": "reviews.md", "kind": "reviews"},
    {"path": "linked/issue_42.md", "kind": "linked_issue"}
  ],
  "linked_items": [
    {"type": "issue", "number": 42, "title": "Original bug report"}
  ],
  "expansion_budget": {"used": 1, "max": 5},
  "warnings": []
}
```

---

## Gathering Behavior

### Issue Triggers

For `:issue` triggers, the gatherer:

1. Fetches the issue via `GitHub.get_issue/1`
2. Fetches comments via `GitHub.list_comments/1` (skipped if `thread_context` is pre-fetched)
3. Renders `trigger.md` — issue title, body, labels, author
4. Renders `thread.md` — chronological comment thread
5. Parses `#NNN` references from body + comments
6. Expands each reference (up to budget) via `GitHub.get_issue/1`
7. Renders each as `linked/issue_NNN.md`

### Pull Request Triggers

For `:pull_request` triggers, the gatherer performs all issue steps plus:

1. Fetches the PR via `GitHub.get_pull_request/1`
2. Fetches PR file list via `GitHub.list_pr_files/1`
3. Fetches reviews via `GitHub.list_reviews/1`
4. Fetches review comments via `GitHub.list_review_comments/1`
5. Renders `diff_stats.md` — table of files changed with +/- counts
6. Renders `reviews.md` — review verdicts and inline comments

### Expansion Rules

- References are extracted via regex: `#(\d+)` (excluding code blocks)
- Maximum expansions per gather: configurable, default 5
- Depth is always 1 — expanded items are NOT scanned for further references
- Each expanded item is fetched via `GitHub.get_issue/1` (works for both issues and PRs)
- Expansion failures are logged as warnings, not errors

---

## Delivery

Delivery writes the bundle to a sprite's filesystem:

1. Clear context directory: `rm -rf /workspace/.lattice/context/`
2. Create directory structure: `mkdir -p /workspace/.lattice/context/linked/`
3. Write `manifest.json` via FileWriter
4. Write each file entry via FileWriter
5. Verify directory listing

Delivery follows the SkillSync pattern: clear → create → write → verify.

---

## Error Handling

- GitHub API failures during gathering return `{:error, term()}`
- Individual expansion failures are recorded as warnings, not fatal errors
- Delivery failures on transient errors are retried (FileWriter handles retry)
- Missing optional data (no reviews, no comments) produces empty files, not errors

---

## Summary

| Concept | Implementation |
|---|---|
| Input | `Lattice.Context.Trigger` struct |
| Output | `Lattice.Context.Bundle` struct |
| Rendering | `Lattice.Context.Renderer` (pure functions) |
| Gathering | `Lattice.Context.Gatherer` (calls GitHub capability) |
| Delivery | `Lattice.Context.Delivery` (writes to sprite via FileWriter) |
| Filesystem | `/workspace/.lattice/context/` |
| Manifest | `manifest.json` (JSON, machine-readable) |
| Expansion | Bounded `#NNN` expansion, depth=1, default budget=5 |
| Skill | `priv/sprite_skills/context/SKILL.md` |
