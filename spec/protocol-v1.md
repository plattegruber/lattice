# Lattice ↔ Sprite Communication Protocol (v1)

> **Status:** Stable v1

This specification defines the durable, event-based communication contract between Sprites and Lattice.

It governs:

- Sprite → Lattice messaging
- Sprite pause / resume semantics
- Human-in-the-loop continuations
- External action requests
- Environment improvement proposals
- Durable workflow coordination via checkpoints

It explicitly **does not** define:

- Bootstrap mechanics
- Coding workflows
- GitHub semantics
- Claude behavior

Those systems are protocol consumers.

---

## Design Principles

1. **Sprites are durable state machines.** Each sprite maintains filesystem state across sessions. Checkpoints are instant (~300ms, copy-on-write) and should be used liberally.
2. **Sprites emit events; Lattice routes and acts.** The event stream is the single source of truth for what happened inside a sprite.
3. **Sprites cannot receive messages except via exec.** There is no push channel. All continuation happens through explicit resume commands.
4. **Checkpoints define explicit continuation boundaries.** A checkpoint is a frozen filesystem state that Lattice can restore and resume from. Restore is sub-second.
5. **Chatty systems are encouraged.** INFO events are cheap. The outbox guarantees durability. More observability is always better.
6. **Sprites propose; Lattice governs.** Sprites may request actions and propose environment changes. Only Lattice performs external operations or mutates system behavior.
7. **All operations must be replayable.** Events are append-only. Checkpoints are idempotent. Resume is deterministic given the same inputs.

---

## Transport

### Sprite → Lattice

Sprites communicate by emitting newline-delimited JSON events to stdout, prefixed with `LATTICE_EVENT `.

```
LATTICE_EVENT {"event_type": "INFO", "sprite_id": "...", "work_item_id": "...", "timestamp": "...", "payload": {"message": "..."}}
```

Lattice parses events in real time during exec sessions via `Lattice.Protocol.Parser`.

Sprites **MUST ALSO** write all events (raw JSON, no prefix) to:

```
/workspace/.lattice/outbox.jsonl
```

Lattice reconciles this outbox post-execution via `Lattice.Protocol.Outbox` to guarantee durability across connection drops and crashes.

### Lattice → Sprite

Lattice communicates exclusively via exec (the Sprites API `cmd` and `exec_ws` endpoints).

There is no push channel. All continuation happens through checkpoint restore followed by exec.

---

## Event Envelope

Every event **MUST** conform to:

```json
{
  "protocol_version": "v1",
  "event_type": "...",
  "sprite_id": "...",
  "work_item_id": "...",
  "timestamp": "ISO-8601",
  "payload": {}
}
```

| Field | Description |
|---|---|
| `protocol_version` | Protocol version identifier. Always `"v1"` for this spec. |
| `event_type` | Protocol-defined event type (see below). |
| `sprite_id` | Immutable sprite identifier (provided by exec context). |
| `work_item_id` | External work reference (issue number, PR number, task ID, etc.). |
| `timestamp` | ISO-8601 emission time. |
| `payload` | Event-specific data. Structure varies by `event_type`. |

Events are **append-only**. Sprites **MUST NOT** mutate or retract prior events.

---

## Core Event Types

### `INFO`

Non-blocking informational message. Used for progress updates, observations, status notes, and general telemetry.

**Payload:**

```json
{
  "message": "Running test suite (75% complete)",
  "kind": "progress",
  "metadata": {"percent": 75, "phase": "test"}
}
```

| Field | Required | Description |
|---|---|---|
| `message` | yes | Human-readable message. Always present as a fallback for display. |
| `kind` | no | Machine-actionable hint. Known kinds: `progress`, `observation`, `assumption`, `note`. Free-form — unknown kinds are logged but not acted on. |
| `metadata` | no | Structured data keyed to the `kind`. For `progress`: `{percent, phase}`. For `assumption`: `{files: [{path, lines, note}]}`. |

INFO events are encouraged. Emit freely.

### `PHASE_STARTED`

Sprite entered a logical phase of work.

**Payload:**

```json
{
  "phase": "implement"
}
```

Phase names are unconstrained. Common phases: `bootstrap`, `implement`, `test`, `polish`, `review`.

### `PHASE_FINISHED`

Sprite completed a logical phase.

**Payload:**

```json
{
  "phase": "implement",
  "success": true
}
```

### `ACTION_REQUEST`

Sprite requests Lattice perform an external action on its behalf. Sprites **MUST NOT** attempt these actions directly.

**Payload:**

```json
{
  "action": "OPEN_PR",
  "parameters": {
    "title": "Fix cache invalidation",
    "body": "...",
    "base": "main",
    "head": "sprite/fix-cache"
  },
  "blocking": false
}
```

| Field | Required | Description |
|---|---|---|
| `action` | yes | Action identifier. Lattice-defined vocabulary (see below). |
| `parameters` | yes | Action-specific parameters. |
| `blocking` | no | Default `false`. When `true`, sprite will emit a `WAITING` event immediately after and expects the action result in the resume payload. |

**Known actions (v1):**

| Action | Description | Typically blocking? |
|---|---|---|
| `OPEN_PR` | Create a pull request | yes |
| `POST_COMMENT` | Post a GitHub comment | no |
| `LABEL_ISSUE` | Add labels to an issue | no |
| `NOTIFY_USER` | Send a notification | no |
| `FETCH_CREDENTIAL` | Retrieve a secret or token | yes |

Actions are Lattice-defined. Sprites may request; Lattice decides whether to fulfill.

**Blocking actions:** For actions whose result is needed to continue work (e.g., the PR URL after `OPEN_PR`), the sprite should:

1. Emit `ACTION_REQUEST` with `blocking: true`
2. Create a checkpoint
3. Emit `WAITING` with `expected_inputs` describing the result shape
4. Exit or suspend

Lattice fulfills the action, then resumes the sprite with the result in the payload.

### `ARTIFACT`

Sprite declares a work product. Used for tracking outputs — branches, commits, files, URLs — that Lattice should record for the dashboard, audit trail, and artifact registry.

**Payload:**

```json
{
  "kind": "branch",
  "ref": "sprite/fix-cache",
  "url": null,
  "metadata": {}
}
```

| Field | Required | Description |
|---|---|---|
| `kind` | yes | Artifact type: `branch`, `commit`, `file`, `pr_url`, `issue_url`, etc. |
| `ref` | no | Identifier — branch name, SHA, PR number, file path. |
| `url` | no | URL if applicable. |
| `metadata` | no | Additional context. |

ARTIFACT is purely declarative. It does not request any action — it records what the sprite produced.

### `WAITING`

Sprite has reached a blocking point and cannot proceed without external input.

**Before emitting WAITING, the sprite MUST:**

1. Create a checkpoint (instant, ~300ms)
2. Include the checkpoint ID in the event
3. Stop meaningful work

**Payload:**

```json
{
  "reason": "PR_REVIEW",
  "checkpoint_id": "chk_abc123",
  "expected_inputs": {
    "approved": "boolean",
    "comments": "array<string>"
  }
}
```

| Field | Required | Description |
|---|---|---|
| `reason` | yes | Why the sprite is waiting. Free-form but should be descriptive. |
| `checkpoint_id` | yes | ID of the checkpoint created before pausing. |
| `expected_inputs` | no | Schema of inputs the sprite expects on resume. Type vocabulary: `string`, `integer`, `boolean`, `map`, `array<T>`. |

**Semantics:**

- Sprite is now paused. The exec session may exit.
- Lattice owns continuation.
- Lattice restores the checkpoint and execs the resume command when ready.

WAITING replaces prior `NEEDS_HUMAN` / `blocked` / `question` semantics with a single, checkpoint-backed pause primitive.

### `COMPLETED`

Sprite has finished all work on the current work item.

**Payload:**

```json
{
  "status": "success",
  "summary": "Implemented cache invalidation, all tests passing."
}
```

| Field | Required | Description |
|---|---|---|
| `status` | yes | `"success"` or `"failure"`. |
| `summary` | no | Human-readable summary of what was accomplished or why it failed. |

COMPLETED signals the end of the work item lifecycle. Lattice should finalize the run.

### `ERROR`

Unrecoverable failure. The sprite cannot continue.

**Payload:**

```json
{
  "message": "Build failed with exit code 1 after 3 retries",
  "details": {
    "phase": "test",
    "exit_code": 1,
    "attempts": 3
  }
}
```

Sprite **SHOULD** create a checkpoint before emitting ERROR when possible, to enable post-mortem inspection.

### `ENVIRONMENT_PROPOSAL`

Sprite proposes an improvement to its environment or setup. Sprites **MUST NOT** apply changes themselves.

**Payload:**

```json
{
  "observed_failure": {
    "phase": "bootstrap",
    "exit_code": 127,
    "stderr_hint": "bash: node: command not found"
  },
  "suggested_adjustment": {
    "type": "runtime_install",
    "details": {
      "runtime": "node",
      "version": "20"
    }
  },
  "confidence": 0.85,
  "evidence": ["package.json present", "no .nvmrc found"],
  "scope": "repo_specific"
}
```

| Field | Required | Description |
|---|---|---|
| `observed_failure` | yes | What went wrong: `phase`, `exit_code`, `stderr_hint`. |
| `suggested_adjustment` | yes | What to change: `type` + `details`. |
| `confidence` | yes | Float 0.0–1.0. How confident the sprite is in its diagnosis. |
| `evidence` | yes | List of observations supporting the proposal. |
| `scope` | yes | `"repo_specific"` or `"global_candidate"`. |

**Allowed adjustment types (v1):**

- `runtime_install`
- `runtime_version_adjust`
- `dependency_manager_switch`
- `add_preinstall_step`
- `adjust_smoke_command`
- `add_system_package`
- `enable_network_access`
- `escalate_to_human`

ENVIRONMENT_PROPOSAL is **asynchronous and fire-and-forget**. Sprites never receive acceptance feedback in the same session. Accepted changes apply only to future runs.

---

## Resume Semantics (Lattice → Sprite)

Lattice resumes sprites via checkpoint restore followed by exec:

1. **Restore checkpoint:** `POST /v1/sprites/{name}/checkpoints/{id}/restore` (sub-second)
2. **Write resume context:** Place inputs at `/workspace/.lattice/resume.json`
3. **Exec continuation:** Run the sprite's resume entrypoint

**Resume payload** (`/workspace/.lattice/resume.json`):

```json
{
  "work_item_id": "...",
  "checkpoint_id": "chk_abc123",
  "inputs": {},
  "context": {}
}
```

**Sprite responsibilities on resume:**

1. Read `/workspace/.lattice/resume.json`
2. Emit `INFO` acknowledging resume
3. Continue workflow from checkpoint state

**Resume MUST be idempotent.** Sprites MUST tolerate duplicate resumes:

- Same checkpoint + same payload → no-op (already processed)
- Same checkpoint + different payload → re-process with new inputs
- Sprites detect duplicates by checking if the checkpoint was already consumed (e.g., presence of a `/workspace/.lattice/resumed` marker file)

---

## Checkpoint Contract

Checkpoints are instant (~300ms, copy-on-write) and cheap (incremental storage). Sprites should checkpoint **liberally** — before any blocking point, before risky operations, and at natural phase boundaries.

When emitting `WAITING`:

- Checkpoint creation is **mandatory**
- Checkpoint ID must be included in the event
- Sprite must stop meaningful work after emitting

When emitting `ERROR`:

- Checkpoint creation is **strongly recommended** (enables post-mortem)
- Not mandatory (the error may prevent checkpointing)

At phase boundaries:

- Checkpoint creation is **recommended** (enables partial replay)

---

## ENVIRONMENT_PROPOSAL Handling (Lattice)

Lattice **MUST:**

1. Validate proposal against the payload schema
2. Deduplicate by content fingerprint (`{phase, exit_code, adjustment_type, adjustment_details}` — not timestamp)
3. Store proposal with status: `pending` → `verified` | `rejected`

**Handling by scope:**

| Scope | Verification | Approval |
|---|---|---|
| `repo_specific` | CI acts as validator (no fresh-sprite test required) | Auto-accept if CI passes |
| `global_candidate` | Fresh-sprite verification required | Explicit human approval |

Sprites are not notified synchronously of proposal outcomes. Accepted changes apply only to future runs.

---

## Ordering

- Events are ordered by stdout emission within a session.
- Sprites SHOULD emit events synchronously with state transitions.
- Lattice treats the event stream as append-only.
- Cross-session ordering is determined by `timestamp`.

---

## Durability

All protocol events **MUST** be written to `/workspace/.lattice/outbox.jsonl`.

Lattice reconciles the outbox after exec sessions via `Lattice.Protocol.Outbox.reconcile/2`, deduplicating by `{event_type, timestamp}`.

This guarantees:

- Crash safety (events survive connection drops)
- Replay (full event history for any work item)
- Forensic inspection (post-mortem analysis)

---

## Authority Model

| Actor | Can | Cannot |
|---|---|---|
| **Sprite** | Execute code, observe environment, emit events, propose actions, create checkpoints | Push to git, call GitHub APIs, modify infrastructure, apply env proposals |
| **Lattice** | Perform external actions, mediate humans, resume sprites, validate proposals, mutate system behavior | Execute inside sprites except via exec |

Sprites never directly mutate external systems.

---

## Security

- All sprite output is **untrusted**. Lattice validates every ACTION_REQUEST.
- Resume payloads are sanitized.
- Sprites never receive raw credentials unless explicitly authorized via `FETCH_CREDENTIAL` flow.
- System package installs (`add_system_package`) require policy approval.
- ENVIRONMENT_PROPOSAL cannot request arbitrary shell commands — only structured adjustment types.

---

## Observability

- Lattice SHOULD persist all events (ETS now, PostgreSQL later).
- INFO events SHOULD be surfaced to users (LiveView dashboard, GitHub comments, etc.).
- PHASE_STARTED / PHASE_FINISHED enable timing analysis.
- ARTIFACT events feed the artifact registry and dashboard.
- All events emit `:telemetry` for metrics.

---

## Summary

| Concept | Implementation |
|---|---|
| Uplink (Sprite → Lattice) | stdout `LATTICE_EVENT` prefix + `/workspace/.lattice/outbox.jsonl` |
| Downlink (Lattice → Sprite) | Checkpoint restore + exec |
| Pause | `WAITING` + mandatory checkpoint |
| Resume | Restore checkpoint → write `resume.json` → exec |
| External actions | `ACTION_REQUEST` (fire-and-forget or blocking + WAITING) |
| Work products | `ARTIFACT` (declarative, no side effects) |
| Environment evolution | `ENVIRONMENT_PROPOSAL` (async, fire-and-forget) |
| Completion | `COMPLETED` with status + summary |
| Failure | `ERROR` with optional checkpoint for post-mortem |

Sprites are durable, chatty state machines. Lattice is the orchestrator and governor. Checkpoints are continuations. Exec is the downlink. Stdout + outbox are the uplink.
