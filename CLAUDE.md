# CLAUDE.md — Lattice

> Required reading before any work: this file, then PHILOSOPHY.md.

## What is Lattice

Lattice is an **Elixir/Phoenix control plane for managing AI coding agents ("Sprites")**. It provides:

- **LiveView dashboard** — real-time ops pane for fleet visibility (the "NOC glass")
- **Sprite-per-process model** — each Sprite is a GenServer managed by a Fleet Manager
- **Capability modules** — bounded interfaces to external systems (GitHub, Fly.io, Sprites API)
- **GitHub human-in-the-loop** — issue-based approval workflows for risky Sprite actions
- **Event-driven observability** — Telemetry + PubSub, LiveView renders projections (never polls)
- **Safety guardrails** — action classification, gating, audit logging

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  Phoenix/LiveView                │
│         (Fleet Dashboard, Sprite Detail,         │
│          Incidents, Approvals Queue)             │
├─────────────────────────────────────────────────┤
│                  Fleet Manager                   │
│         (DynamicSupervisor, Registry)            │
├──────────┬──────────┬──────────┬────────────────┤
│ Sprite 1 │ Sprite 2 │ Sprite N │  (GenServers)  │
├──────────┴──────────┴──────────┴────────────────┤
│              Capability Modules                  │
│   GitHubCapability │ FlyCapability │ SpritesAPI  │
├─────────────────────────────────────────────────┤
│         Telemetry + PubSub (Event Bus)           │
├─────────────────────────────────────────────────┤
│              Safety & Guardrails                 │
│     (Action Classification, Gating, Audit)       │
└─────────────────────────────────────────────────┘
```

### Key Mental Models

- **Sprites are processes.** Each Sprite gets a GenServer that owns its state, reads its logs, and observes the Sprites API for status.
- **Events are truth.** State changes emit Telemetry events. PubSub broadcasts them. LiveView subscribes and renders. No polling.
- **Capabilities are behaviours.** Each external system (GitHub, Fly, Sprites API) gets a behaviour module. This enables clean mocking, testing, and future swapping.
- **Safety is first-class.** Every action is classified (safe/needs-review/dangerous), gated, and audit-logged.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.18+ / OTP 27+ |
| Web | Phoenix 1.7+ / LiveView 1.0+ |
| Process model | GenServer, DynamicSupervisor, Registry |
| Events | :telemetry + Phoenix.PubSub |
| Persistence | ETS initially, PostgreSQL later |
| Auth | Bearer token (current) / Clerk integration available |
| Deployment | Fly.io + Fly Scheduled Machines |
| CI | GitHub Actions |

## Project Structure (target)

```
lattice/
├── .claude/                    # Claude Code hooks & config
│   ├── hooks/session-start.sh  # Remote session bootstrap
│   └── settings.json           # Hook configuration
├── .github/workflows/          # CI/CD
├── lib/
│   ├── lattice/
│   │   ├── sprites/
│   │   │   ├── sprite.ex           # Sprite GenServer
│   │   │   ├── fleet_manager.ex    # DynamicSupervisor + Registry
│   │   │   └── state.ex            # Sprite state struct
│   │   ├── capabilities/
│   │   │   ├── capability.ex       # Behaviour definition
│   │   │   ├── github.ex           # GitHub HITL
│   │   │   ├── fly.ex              # Fly.io management
│   │   │   └── sprites_api.ex      # Sprites API client
│   │   ├── safety/
│   │   │   ├── classifier.ex       # Action classification
│   │   │   ├── gate.ex             # Approval gating
│   │   │   └── audit.ex            # Audit logging
│   │   ├── events.ex               # Telemetry + PubSub helpers
│   │   └── application.ex          # OTP application
│   ├── lattice_web/
│   │   ├── live/
│   │   │   ├── fleet_live.ex       # Fleet dashboard
│   │   │   ├── sprite_live.ex      # Sprite detail
│   │   │   ├── incidents_live.ex   # Incidents view
│   │   │   └── approvals_live.ex   # Approval queue
│   │   ├── controllers/
│   │   │   └── api/                # REST API
│   │   └── router.ex
│   └── lattice_web.ex
├── test/
├── config/
├── CLAUDE.md                   # You are here
├── PHILOSOPHY.md               # Design principles
├── README.md                   # Project overview
├── mix.exs
├── fly.toml
└── Dockerfile
```

## Commands

```bash
# Development
mix setup              # Install deps, create db, run migrations
mix phx.server         # Start dev server (localhost:4000)
iex -S mix phx.server  # Start with IEx shell attached

# Testing
mix test               # Run all tests
mix test --only unit   # Run unit tests only
mix test path/to/test  # Run specific test file

# Quality
mix format             # Format code
mix format --check-formatted  # Check formatting (CI)
mix credo --strict     # Static analysis
mix dialyzer           # Type checking (slow first run)

# Build
mix compile --warnings-as-errors  # Compile with strict warnings
```

## Coding Conventions

### Elixir Style

- **Pattern match eagerly.** Use pattern matching in function heads, not `if/case` inside the body.
- **Let it crash.** Supervisors handle failures. Don't wrap everything in `try/rescue`.
- **Pipe clearly.** `|>` chains should read top-to-bottom. If a pipe chain gets unclear, extract a named function.
- **Structs for domain types.** `%Sprite{}`, `%Action{}`, `%AuditEntry{}` — not bare maps.
- **Contexts over controllers.** Business logic lives in context modules, never in controllers or LiveView.

### Phoenix/LiveView

- **LiveView handles display, not logic.** `handle_event` should delegate to contexts.
- **PubSub, not polling.** Subscribe to topics in `mount/3`, render from assigns.
- **Functional components** for reusable UI pieces. LiveComponents only when they need their own lifecycle.
- **HEEX templates** colocated with their LiveView modules.

### OTP

- **GenServer state should be a struct.** Define a `%State{}` struct in the module.
- **Handle_info for PubSub messages.** Keep `handle_call` for sync queries, `handle_cast` for fire-and-forget.
- **Timeouts and `:continue`** for periodic work. Not `Process.send_after` loops unless needed.

### Testing

- **Test the behaviour, not the implementation.** Test public APIs of modules.
- **Use behaviours for external deps.** Mock at the behaviour boundary with Mox.
- **ExUnit tags** for test categorization: `@tag :unit`, `@tag :integration`.
- **Factories over fixtures.** Use ExMachina or simple factory functions.

### Commits & PRs

- **Vertical slices only.** Each PR delivers one complete, working feature top-to-bottom.
- **Imperative commit messages.** "Add fleet dashboard", not "Added fleet dashboard".
- **Small PRs.** If it's hard to review, it's too big.

## Instance Configuration

Each Lattice deployment binds to specific external resources:

```elixir
# config/runtime.exs
config :lattice, :instance,
  name: System.get_env("LATTICE_INSTANCE_NAME", "lattice-dev"),
  environment: config_env()

config :lattice, :resources,
  github_repo: System.get_env("GITHUB_REPO"),
  fly_org: System.get_env("FLY_ORG"),
  fly_app: System.get_env("FLY_APP"),
  sprites_api_base: System.get_env("SPRITES_API_BASE")
```

## API Contract

The `/api` scope is protected by bearer token auth (`Authorization: Bearer <token>`) via `LatticeWeb.Plugs.Auth`. Unauthenticated requests receive a `401` response.

**Response envelope:**

- Success: `%{data: ..., timestamp: DateTime.utc_now()}`
- Error: `%{error: "message", code: "ERROR_CODE"}`

**Status codes:**

| Code | Meaning |
|------|---------|
| `200` | Success |
| `401` | Missing or invalid bearer token |
| `404` | Resource not found (e.g., `SPRITE_NOT_FOUND`) |
| `422` | Validation error (e.g., `INVALID_STATE`, `MISSING_FIELD`, `INVALID_STATE_TRANSITION`) |

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/fleet` | Fleet summary |
| `POST` | `/api/fleet/audit` | Trigger fleet-wide reconciliation |
| `GET` | `/api/sprites` | List all sprites |
| `GET` | `/api/sprites/:id` | Sprite detail |
| `POST` | `/api/sprites` | Create a sprite |
| `POST` | `/api/sprites/:id/wake` | Wake a sleeping sprite |
| `POST` | `/api/sprites/:id/sleep` | Sleep a running sprite |
| `PUT` | `/api/sprites/:id/tags` | Update sprite tags/metadata |
| `DELETE` | `/api/sprites/:id` | Delete a sprite (dangerous) |
| `POST` | `/api/sprites/:id/reconcile` | Trigger sprite reconciliation |
| `POST` | `/api/sprites/:id/exec` | Start exec session (WebSocket-backed) |
| `GET` | `/api/sprites/:id/sessions` | List active exec sessions |
| `GET` | `/api/sprites/:id/sessions/:sid` | Exec session detail with output |
| `DELETE` | `/api/sprites/:id/sessions/:sid` | Terminate exec session |
| `POST` | `/api/sprites/:name/tasks` | Create a task on a sprite |
| `GET` | `/api/intents` | List intents |
| `GET` | `/api/intents/:id` | Intent detail |
| `POST` | `/api/intents` | Create intent |
| `POST` | `/api/intents/:id/approve` | Approve an intent |
| `POST` | `/api/intents/:id/reject` | Reject an intent |
| `POST` | `/api/intents/:id/cancel` | Cancel an intent |
| `GET` | `/api/runs` | List runs (filter: intent_id, sprite_name, status) |
| `GET` | `/api/runs/:id` | Run detail |
| `POST` | `/api/runs/:id/answer` | Answer a blocked run's question |
| `GET` | `/api/sprites/:name/skills` | List available skills for a sprite |
| `GET` | `/api/sprites/:name/skills/:skill_name` | Skill detail with manifest |

`GET /health` is unauthenticated.

## Branch Protection

The `main` branch should have these protection rules configured in GitHub (Settings > Branches > Branch protection rules):

- **Require status checks to pass before merging** — select both `Build and test` and `Prod compile check` jobs
- **Require branches to be up to date before merging** — ensures PRs are tested against the latest main
- **Require pull request reviews before merging** (optional) — at least 1 approval recommended

These rules must be set manually in the GitHub UI. They cannot be applied via CI.

## Issue Tracker

Active issues are in [github.com/plattegruber/lattice/issues](https://github.com/plattegruber/lattice/issues).

Phases:
1. **Foundation** (done) — capability architecture, event infrastructure, safety framework, CI
2. **Step 1** (done) — scaffold, sprite processes, fleet manager, LiveView dashboard
3. **Step 2** (done) — real Sprites API integration, reconciliation, Phoenix API
4. **Step 3** (done) — GitHub HITL workflow, approvals queue
5. **Step 4** (done) — Fly deployment, Scheduled Machines
