# Lattice Context Bundle

You are running inside a Lattice-managed sprite. Before you start working,
Lattice has gathered context about the issue or pull request that triggered
your task. This document teaches you how to read and use that context.

## Where Context Lives

```
/workspace/.lattice/context/
├── manifest.json          # Bundle metadata + file index
├── trigger.md             # The issue or PR that triggered this work
├── thread.md              # Comment thread (chronological)
├── diff_stats.md          # Files changed in the PR (PRs only)
├── reviews.md             # Review verdicts + inline comments (PRs only)
└── linked/
    └── issue_NNN.md       # Expanded cross-references
```

Not all files are always present. Check `manifest.json` to see what was gathered.

## Step 1: Read the Manifest

Start by reading `/workspace/.lattice/context/manifest.json`:

```json
{
  "version": "v1",
  "trigger_type": "issue",
  "trigger_number": 42,
  "repo": "owner/name",
  "title": "The issue title",
  "gathered_at": "2026-02-23T12:00:00Z",
  "files": [
    {"path": "trigger.md", "kind": "trigger"},
    {"path": "thread.md", "kind": "thread"},
    {"path": "linked/issue_10.md", "kind": "linked_issue"}
  ],
  "linked_items": [
    {"type": "issue", "number": 10, "title": "Related issue"}
  ],
  "expansion_budget": {"used": 1, "max": 5},
  "warnings": []
}
```

The manifest tells you:
- **trigger_type**: Whether this is an `issue` or `pull_request`
- **files**: Which context files are available
- **linked_items**: Cross-referenced issues that were expanded
- **warnings**: Any issues during context gathering

## Step 2: Read the Trigger

`trigger.md` contains the primary issue or PR:
- Title and metadata (author, state, labels)
- The full description/body
- For PRs: branch information, changed files summary, and reviews

This is the most important file. Start here to understand what you need to do.

## Step 3: Read the Thread

`thread.md` contains the comment thread in chronological order.
Each comment shows the author, timestamp, and body.
Read this to understand the full conversation and any clarifications.

## Step 4: Read PR-Specific Files (if present)

For pull request triggers:

- **diff_stats.md** — Table of files changed with additions/deletions counts.
  Use this to understand the scope of changes.
- **reviews.md** — Review verdicts (APPROVED, CHANGES REQUESTED, COMMENTED)
  and inline review comments grouped by file. Use this to understand what
  reviewers want changed.

## Step 5: Check Linked Items

The `linked/` directory contains expanded cross-references (`#NNN`) found in
the trigger body and comments. Each is rendered as a standalone issue/PR document.

Not all references are expanded — check the manifest's `expansion_budget` to see
how many were expanded vs. the maximum. If you need context from a reference that
wasn't expanded, you can fetch it directly using `gh`.

## Using Context Effectively

1. **Read trigger.md first** — understand the task
2. **Read thread.md** — catch any clarifications or follow-up discussion
3. **Check linked items** — understand related context
4. **For PRs: read reviews.md** — understand what reviewers want
5. **For PRs: read diff_stats.md** — understand scope of changes

## Hard Rules

You MUST:
- Read `manifest.json` before accessing context files
- Check which files exist before trying to read them
- Use context to inform your work, not as the sole source of truth

You MUST NOT:
- Modify files in `/workspace/.lattice/context/` — they are read-only reference
- Assume all files are present — check the manifest
- Ignore warnings in the manifest
