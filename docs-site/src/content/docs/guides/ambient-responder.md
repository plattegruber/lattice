---
title: Ambient Responder
description: How Lattice monitors GitHub events and autonomously responds, delegates questions, or implements code changes.
---

The **Ambient Responder** watches GitHub issues and pull requests in real time. When someone asks a question, requests a code change, or opens an issue, Lattice classifies the event and takes the appropriate action -- from adding a reaction to opening a full pull request.

## How It Works

```
GitHub Webhook (issue_comment, issue_opened, pr_review, ...)
    │
    ▼
Ambient Responder (GenServer)
    ├── 👀 reaction (immediate acknowledgment)
    ├── Fetch thread context (last 10 comments)
    ├── Claude classification
    │
    ├── implement  → Sprite creates branch, makes changes, pushes
    │                  → Lattice creates PR + comments on issue
    ├── delegate   → Sprite runs claude -p with repo context
    │                  → Lattice posts answer as comment
    ├── respond    → Claude generates response directly
    │                  → Lattice posts as comment
    ├── react      → 👍 reaction
    └── ignore     → No action
```

## Classification

The Claude classifier examines each event and its thread context to decide the best response. Decisions are checked in priority order:

| Decision | When | Example |
|----------|------|---------|
| **implement** | Explicit request to write code | "implement this", "fix this bug", "build this feature" |
| **delegate** | Question that needs codebase context | "How does the fleet manager work?", "What file handles auth?" |
| **respond** | General question, no codebase needed | "What do you think of this approach?" |
| **react** | Acknowledgment, no reply needed | "sounds good", "done", "merged" |
| **ignore** | Noise (bots, CI, auto-generated) | Dependabot PRs, CI status comments |

## Implementation Flow

When someone comments "implement this" (or similar) on an issue, Lattice:

1. **Acknowledges** with a 👀 reaction
2. **Classifies** the event as `:implement`
3. **Delegates to a sprite** which:
   - Checks out a new branch: `lattice/issue-{N}-{slug}`
   - Runs Claude Code in agentic mode to make changes
   - Commits with message: `lattice: implement #{N} - {title}`
   - Pushes the branch using a GitHub App token
4. **Creates a PR** via the GitHub capability (logged through telemetry)
5. **Comments on the issue** with a link to the PR

```
Sprite (code changes only)          Lattice (GitHub API, fully audited)
├── git checkout -b branch          ├── GitHub.create_pull_request(...)
├── claude -p "implement..."        ├── GitHub.create_comment(...)
├── git add -A && git commit        └── Record cooldown
└── git push (via app token)
```

**Key safety property:** The sprite only does git operations. All GitHub API interactions (PR creation, issue comments) go through Lattice's capability layer with full telemetry logging.

### Error Handling

| Outcome | Lattice Response |
|---------|-----------------|
| Success | Creates PR, comments with link |
| No changes produced | Posts helpful comment explaining no changes were made |
| Push/commit failure | Adds confused reaction, posts error comment |
| PR creation fails | Comments with branch name so changes aren't lost |

## Delegation Flow

When someone asks a question that needs codebase context:

1. **Acknowledges** with a 👀 reaction
2. **Classifies** as `:delegate`
3. **Runs `claude -p`** on a sprite with the full repo cloned
4. **Posts the answer** as a comment on the issue/PR

The sprite is reused across requests -- if it already exists, Lattice pulls the latest code. If not, it creates the sprite and clones the repo.

## Self-Loop Prevention

Two layers prevent Lattice from responding to its own messages:

1. **Webhook filter** -- events from Lattice's GitHub App user are filtered at the webhook layer
2. **Bot login check** -- the Responder checks `event.author` against the configured `bot_login`

## Cooldown

A per-thread cooldown prevents responding to the same issue/PR more than once within a configurable window (default: 60 seconds). This applies to all decision types that produce output (implement, delegate, respond, react).

## Configuration

```bash
# Required
ANTHROPIC_API_KEY=sk-ant-...          # Enables ambient classification

# Sprite delegation (required for delegate + implement)
AMBIENT_DELEGATION=true               # Enable sprite-based features
AMBIENT_SPRITE_NAME=lattice-ambient   # Sprite name to use
AMBIENT_DELEGATION_TIMEOUT_MS=120000  # Delegation timeout (2 min)
AMBIENT_IMPLEMENTATION_TIMEOUT_MS=300000  # Implementation timeout (5 min)

# Responder behavior
AMBIENT_COOLDOWN_MS=60000             # Per-thread cooldown
LATTICE_BOT_LOGIN=lattice-bot[bot]    # Bot username for self-loop prevention
AMBIENT_MODEL=claude-sonnet-4-20250514  # Claude model for classification

# GitHub App (for pushing branches)
GITHUB_APP_ID=12345
GITHUB_APP_INSTALLATION_ID=67890
GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----\n..."
```
