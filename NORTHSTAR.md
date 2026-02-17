# Lattice end-state technical design (control plane + agent runtime)

This doc is the north star for Lattice: a GitHub-native, human-in-the-loop control plane that orchestrates Sprites (persistent sandboxes) to do real work (plan, execute, open PRs, iterate on feedback, keep systems healthy).

It is written to be handed to Claude Code to implement as a series of issues/PRs.

---

## Goals

### What "done" looks like (interaction-level)
We want these loops to feel effortless:

1. **Issue → dialogue → plan**
   - User creates a GitHub issue.
   - System comments with clarifying questions and/or a concrete plan.
   - User answers, system updates plan, then begins work (or asks for approval).

2. **Plan → PR → feedback → fixups**
   - System creates a PR.
   - User reviews and leaves comments.
   - System pushes follow-up commits until green / approved.

3. **New Project → epics/tasks**
   - User creates a new GitHub Project (or a "project issue"/seed doc).
   - System proposes epics/tasks and creates issues (or drafts them for approval).

4. **Open-ended project questions → research dialogue**
   - User creates project + open questions.
   - System researches, replies with sourced notes, then proposes a plan.

5. **Unhealthy system → detect → fix (cron)**
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

### Major components
1. **Lattice Control Plane (Phoenix + LiveView)**
   - API endpoints (kickoff, status, logs, intents).
   - Real-time UI fed via PubSub events.

2. **Intent Pipeline**
   - The governance layer: propose → classify → gate → execute.
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

## Sprites API: what we can rely on

The Sprites API supports:
- **Create Sprite**: `POST /v1/sprites` with `{ "name": "...", "url_settings": { "auth": "sprite"|"public" } }`
- **List/Get/Update/Delete** sprites
- **Exec** command via WebSocket: `WSS /v1/sprites/{name}/exec` (TTY, streaming, sessions, detach/attach)
- **Services** management: list/create/start/stop services inside a sprite
- **Checkpoints** (snapshots/restore) and **Network policy**

**Implication:**
- We *can* implement the "POST endpoint → sprite exists → show in UI" loop immediately.
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

Start small but map directly to your interaction examples.

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
- `create_sprite(name, opts)` → sprite
- `list_sprites(opts)` → sprites
- `get_sprite(name)` → sprite
- `delete_sprite(name)` → ok
- `exec_ws(name, cmd/args, opts)` → session handle + streaming
- `exec_post(name, cmd/args, stdin, opts)` → output
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

You already have "PubSub events flowing from processes to LiveView". Standardize the payloads now so every executor can emit consistent progress.

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
