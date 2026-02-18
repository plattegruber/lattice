# Lattice north star — control plane + agent runtime

This doc is the north star for Lattice: a GitHub-native, human-in-the-loop control plane that orchestrates Sprites (secure sandboxes that expose composable skills) to do real work.

It is written to be handed to Claude Code to implement as a series of issues/PRs.

---

## The core idea

**Sprites are not agents. Sprites are secure sandboxes that expose composable skills.**

Lattice owns:
- Intent
- Planning
- Governance
- Memory
- Human-in-the-loop (GitHub)
- Observability

Sprites own:
- Execution
- Emitting structured signals
- Producing artifacts

This separation keeps the system safe, debuggable, and evolvable.

**Key architectural rule:** Sprites emit signals. Lattice makes decisions.

---

## High-level model

```
GitHub / API / Cron
      |
    Signal
      |
    Intent
      |
 Gate / Approve
      |
     Run
      |
    Sprite
      |
    Skills
      |
Artifacts + Events
```

Sprites never decide what to do. They only perform skills and report outcomes.

---

## Goals

### What "done" looks like (interaction-level)
We want these loops to feel effortless:

1. **Issue -> dialogue -> plan**
   - User creates a GitHub issue.
   - System comments with clarifying questions and/or a concrete plan.
   - User answers, system updates plan, then begins work (or asks for approval).

2. **Plan -> PR -> feedback -> fixups**
   - System creates a PR.
   - User reviews and leaves comments.
   - System pushes follow-up commits until green / approved.

3. **New Project -> epics/tasks**
   - User creates a new GitHub Project (or a "project issue"/seed doc).
   - System proposes epics/tasks and creates issues (or drafts them for approval).

4. **Open-ended project questions -> research dialogue**
   - User creates project + open questions.
   - System researches, replies with sourced notes, then proposes a plan.

5. **Unhealthy system -> detect -> fix (cron)**
   - A periodic job detects a failing condition.
   - System creates an issue (if needed), proposes remediation, executes, opens PR.

6. **Documentation upheld**
   - When code changes, docs are updated (or an issue is created if docs lag).

### Constraints / philosophy
- **GitHub is the HITL substrate.** Approvals, plans, audits, and state should be legible in issues/PRs/projects.
- **Control plane is explicit and observable.** Users can see "what is happening" in the UI in real time.
- **Agent runtime is sandboxed.** Work happens in Sprites; Lattice coordinates and audits.
- **Small steps, always shippable.** Build the minimal "vertical slices" that prove the loop.

---

## Non-goals (for now)
- Fully autonomous long-running business workflows without explicit human gates.
- Complex multi-repo dependency planning.
- Perfect natural language understanding. Prefer explicit intent types + schemas.

---

## System overview

### Lattice vs. Sprites — ownership boundary

| Lattice (control plane) | Sprites (execution) |
|--------------------------|---------------------|
| Receives signals (webhooks, API, cron) | Executes commands |
| Creates and manages intents | Runs skills |
| Classifies and gates actions | Emits logs + structured events |
| Dispatches runs to sprites | Produces artifacts (files, branches, PR URLs) |
| Manages human-in-the-loop | Reports outcomes |
| Persists state and memory | --- |
| Observes and audits everything | --- |

A Sprite does NOT:
- Approve intents
- Manage state
- Talk directly to users
- Create new sprites
- Alter policies
- Decide workflows

Sprites are workers, not brains.

### Major components
1. **Lattice Control Plane (Phoenix + LiveView)**
   - API endpoints (kickoff, status, logs, intents).
   - Real-time UI fed via PubSub events.

2. **Intent Pipeline**
   - The governance layer: propose -> classify -> gate -> execute.
   - Produces an auditable trail (events + persisted intent state).
   - Dispatches to executors.

3. **Capabilities**
   - Pluggable adapters to external systems:
     - **Sprites** (create/list/get/destroy, exec, services, checkpoints, network policy)
     - **GitHub** (issues, comments, PRs, reviews, labels, projects)
     - **Fly** (optional; deployment/infra hooks)

4. **Executors (agent runtime orchestration)**
   - The "doing work" part.
   - "Tell sprite to do X, stream output, interpret results, open PR."

5. **Sprite lifecycle manager**
   - Fleet manager reconciles desired vs observed sprites.
   - Sprites are persistent sandboxes; Lattice can create/delete them dynamically.

---

## Skills

A skill is a small, focused executable available inside the Sprite.

```
/skills
├── git.clone
├── git.commit
├── git.push
├── github.open_pr
├── fs.read
├── fs.write
├── test.run
└── agent.run       # get-shit-done / Claude Code / OpenClaw
```

Each skill:
- Accepts structured input (env vars or stdin JSON)
- Performs one responsibility
- Emits stdout/stderr
- May emit structured events
- Returns exit status

Skills do not contain orchestration logic. Lattice composes skills into workflows.

### Skill contract

```
input JSON/env
      |
   execute
      |
stdout/stderr + structured events
      |
   exit code
```

Skills may optionally expose a `skill.json` manifest:

```json
{
  "name": "github.open_pr",
  "inputs": ["title", "body", "branch"],
  "outputs": ["pr_url"],
  "permissions": ["github:write"],
  "produces_events": true
}
```

This allows Lattice to:
- Preflight permissions
- Validate plans
- Explain actions to users

---

## Sprite <-> Lattice communication

### Sprite -> Lattice: structured events

Sprites never call Lattice business APIs. They emit signals.

Primary mechanism: structured stdout events. The Sprite writes JSON lines with a sentinel prefix:

```
LATTICE_EVENT {"type": "artifact", "kind": "pr", "url": "https://github.com/org/repo/pull/123"}
```

Lattice parses these from exec streams.

#### Supported event types

**question** — Sprite is blocked and needs user input.
```json
{
  "type": "question",
  "prompt": "Should we use Ecto.Multi here?",
  "choices": ["Ecto.Multi", "separate transactions"],
  "default": "Ecto.Multi"
}
```
Effect: Run enters `blocked_waiting_for_user`. Lattice posts GitHub comment / UI prompt.

**assumption** — Sprite made a best guess and wants review.
```json
{
  "type": "assumption",
  "files": [
    {
      "path": "lib/foo.ex",
      "lines": [120, 121],
      "note": "Assumed X because Y"
    }
  ]
}
```
Effect: Lattice creates PR comments or summary notes.

**artifact** — Sprite produced something meaningful.
```json
{
  "type": "artifact",
  "kind": "pr",
  "url": "https://github.com/org/repo/pull/123"
}
```
Effect: Artifact attached to Run. Rendered in UI.

**blocked** — Sprite cannot proceed.
```json
{
  "type": "blocked",
  "reason": "Missing API key"
}
```

**progress / warning / checkpoint** — Informational events.

#### Outbox (optional reliability layer)

Sprites may also write structured messages to `/workspace/.lattice/outbox.jsonl`.

Lattice can fetch this file after execution for guaranteed delivery of events. Useful for:
- Large payloads
- Non-streaming environments
- Crash recovery

### Lattice -> Sprite: inputs

Lattice provides data via the filesystem or environment variables.

**Task payload** — written to `/workspace/.lattice/task.json`:
```json
{
  "run_id": "...",
  "goal": "...",
  "repo": "...",
  "constraints": {},
  "acceptance": "...",
  "answers": {}
}
```

**User answers** — if a sprite asks a question, answers are written to `/workspace/.lattice/answers.json`. A new Run may be started with updated inputs.

Sprites are not required to stay alive between runs.

---

## Permission model

Sprites operate with minimal privileges.

**Filesystem:**
- `/workspace` (read/write)
- `/skills` (read-only)

**Network:**
- GitHub API
- Optionally Lattice event endpoint (future)

**Tokens:**
- Scoped GitHub token
- Short-lived run token (events only)

Sprites cannot:
- Approve intents
- Spawn sprites
- Modify control plane state
- Escalate permissions

All governance happens in Lattice.

---

## Sprites API: what we can rely on

The Sprites API supports:
- **Create Sprite**: `POST /v1/sprites` with `{ "name": "...", "url_settings": { "auth": "sprite"|"public" } }`
- **List/Get/Update/Delete** sprites
- **Exec** command via WebSocket: `WSS /v1/sprites/{name}/exec` (TTY, streaming, sessions, detach/attach)
- **Services** management: list/create/start/stop services inside a sprite
- **Checkpoints** (snapshots/restore) and **Network policy**

**Implication:**
- We *can* implement the "POST endpoint -> sprite exists -> show in UI" loop immediately.
- We can implement task execution either:
  - as simple "exec commands" (good for MVP), or
  - as "service" based (good for long-running daemon-like work), or
  - as "exec sessions" (TTY detach/reattach) for streaming progress.

---

## End-state design: core data model

### 1) Sprite (control plane record)
A sprite is both:
- an external resource (Sprites API), and
- a local record with desired state + tags.

**Local fields (proposed)**
- `id` (local ULID)
- `name` (Sprites name)
- `status` (cold/warm/running + local "known state")
- `labels/tags` (e.g. `purpose=repo-work`, `repo=plattegruber/lattice`)
- `created_at`, `last_seen_at`
- `desired_state` (exists? warm? network policy? services?)

### 2) Intent (governed action)
Intent is the unit of "why are we doing this".

**Fields**
- `intent_id`
- `kind` (enum; see below)
- `subject` (what entity it's about: issue/pr/repo/sprite/health check)
- `proposed_by` (system/user/webhook/cron)
- `status` (proposed/classified/gated/executing/succeeded/failed/canceled)
- `gate` (policy decisions, required approvals)
- `plan` (structured steps; stored as JSON)
- `audit_log` (append-only events)

### 3) Run / Execution session
The unit of "doing":
- `run_id`
- `intent_id`
- `sprite_name`
- `mode` (`exec_ws` | `exec_post` | `service`)
- `stream_refs` (where to fetch logs)
- `artifacts` (branch name, PR url, commit SHAs)

---

## Intent kinds (minimum viable set)

Start small but map directly to the interaction examples.

### GitHub-centric
- `issue_triage`
  - input: issue URL + body
  - output: clarifying questions OR plan comment
- `issue_plan_approve`
  - input: plan + approval signal
  - output: begin execution
- `pr_create_from_plan`
  - input: repo + plan + target branch
  - output: PR opened
- `pr_fixup_from_feedback`
  - input: PR URL + review comments
  - output: additional commits pushed

### Sprite-centric
- `sprite_create`
  - input: name, tags, url_settings
  - output: sprite exists + local record
- `sprite_task_exec`
  - input: sprite + command(s) + expectations
  - output: logs + exit status + parsed result

### Ops/health
- `health_detect`
  - input: signal/check definition
  - output: issue created/updated
- `health_remediate`
  - input: remediation plan
  - output: PR or config change

---

## Capability shape (contract)

The goal is: executors call *capabilities*, not raw HTTP.

### Sprites capability (must include create)
**Required methods**
- `create_sprite(name, opts)` -> sprite
- `list_sprites(opts)` -> sprites
- `get_sprite(name)` -> sprite
- `delete_sprite(name)` -> ok
- `exec_ws(name, cmd/args, opts)` -> session handle + streaming
- `exec_post(name, cmd/args, stdin, opts)` -> output
- `services.*` (optional for v1, but wireable)
- `checkpoints.*` (optional v1)
- `policy.*` (optional v1)

This is justified directly by the Sprites API surface.

### GitHub capability (minimum)
- read issue
- create issue comment
- create branch + push commits (or push via token)
- open PR
- read PR review comments + issue comments
- comment on PR
- update PR (push more commits)

---

## LiveView / PubSub event schema (proposed)

### Event envelope
```json
{
  "type": "intent.updated" | "run.output" | "sprite.updated" | "github.updated" | "system.alert",
  "ts": "ISO-8601",
  "trace_id": "ulid/uuid",
  "intent_id": "ulid",
  "run_id": "ulid|null",
  "sprite": { "name": "..." } | null,
  "payload": { ... }
}
```

---

## Runtime evolution

The skills model decouples Lattice from any specific agent runtime.

**Today:**
- Bash scripts
- Deterministic PR generators

**Tomorrow:**
- Get-shit-done
- Claude Code
- OpenClaw

All appear as `/skills/agent.run`. Same interface. Same contract. Lattice remains unchanged.

---

## Why this design matters

This design enables:
- **Tight security boundaries** — sprites can't escalate or self-govern
- **Composable workflows** — skills are small, Lattice composes them
- **Deterministic replay** — structured inputs/outputs make runs reproducible
- **Multiple agent runtimes** — swap the skill, keep the contract
- **GitHub-native HITL** — governance lives where developers already work
- **Clean separation of concerns** — control plane vs. execution, always

It turns Lattice into a control plane for agent workloads.
And Sprites into secure, observable skill runtimes.

That is the system.
