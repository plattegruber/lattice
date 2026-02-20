---
title: Architecture
description: System overview, event model, capability modules, and process supervision in Lattice.
---

Lattice is built on Elixir/OTP, leveraging the BEAM's process model for concurrent, fault-tolerant management of AI coding agents. This page describes how the system fits together.

## System Overview

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

## Key Mental Models

### Sprites Are Processes

Each Sprite gets a GenServer that owns its state, runs reconciliation, and emits events. The BEAM provides isolation, supervision, and fault tolerance. If a Sprite process crashes, its supervisor restarts it automatically.

This is not a microservices architecture. It is an OTP application where concurrency and fault tolerance come from the runtime, not from external infrastructure.

### Events Are Truth

State changes emit Telemetry events. PubSub broadcasts them. LiveView subscribes and renders. The database (when added) is just another projection.

This means:
- No polling, ever
- No "refresh the page to see changes"
- The dashboard is always live

### Capabilities Are Behaviours

Each external system (GitHub, Fly.io, Sprites API, Secret Store) gets a **behaviour module** -- a bounded interface that defines the contract between Lattice and the external system.

This enables:
- **Clean mocking** -- swap live implementations for stubs in tests
- **Auto-selection** -- use live implementations when credentials are present, stubs otherwise
- **Future-proofing** -- add new capabilities by implementing the behaviour

### Safety Is First-Class

Every action flows through the classify-gate-audit pipeline. This is not bolted on -- it is a core architectural concern that shapes how the system processes work.

## Process Supervision Tree

```
Application Supervisor
├── Lattice.PubSub                    (Phoenix.PubSub)
├── LatticeWeb.Endpoint               (Phoenix endpoint)
├── Lattice.Events.TelemetryHandler    (attaches Telemetry handlers)
├── Lattice.Intents.Store.ETS         (intent persistence)
├── Lattice.Intents.Governance.Listener (watches for approved intents)
├── Lattice.Sprites.Registry           (process registry)
├── Lattice.Sprites.DynamicSupervisor  (sprite supervisor)
├── Lattice.Sprites.FleetManager       (fleet coordinator)
├── Lattice.Ambient.TaskSupervisor     (async tasks for ambient responses)
└── Lattice.Ambient.Responder          (GitHub event classifier + responder)
```

## Event Infrastructure

### Telemetry

Lattice uses Erlang's `:telemetry` library for structured event emission. Events follow the `[:lattice, <domain>, <event>]` naming convention:

| Event | Emitted When |
|-------|-------------|
| `[:lattice, :sprite, :state_change]` | Sprite observed state transitions |
| `[:lattice, :sprite, :reconciliation]` | Reconciliation cycle completes |
| `[:lattice, :sprite, :health]` | Sprite health status changes |
| `[:lattice, :fleet, :summary]` | Fleet summary is recomputed |
| `[:lattice, :intent, :proposed]` | New intent is proposed |
| `[:lattice, :intent, :classified]` | Intent receives classification |
| `[:lattice, :intent, :approved]` | Intent is approved |
| `[:lattice, :intent, :awaiting_approval]` | Intent needs human review |
| `[:lattice, :intent, :rejected]` | Intent is rejected |
| `[:lattice, :intent, :canceled]` | Intent is canceled |
| `[:lattice, :safety, :audit]` | Capability action is audit-logged |

### PubSub Topics

Phoenix PubSub provides real-time broadcast to LiveView subscribers:

| Topic | Messages |
|-------|----------|
| `"sprites:fleet"` | `{:fleet_summary, summary}` |
| `"sprites:<sprite_id>"` | State changes, reconciliation results, health updates |
| `"intents:all"` | All intent lifecycle transitions |
| `"intents:<intent_id>"` | Specific intent transitions |
| `"safety:audit"` | Audit entries |
| `"observations:all"` | Sprite observations |
| `"ambient:github"` | GitHub events for ambient classification + response |

## Capability Modules

### Architecture

Each capability follows this pattern:

```
Lattice.Capabilities.<Name>      (behaviour definition)
├── Lattice.Capabilities.<Name>.Live   (real implementation)
├── Lattice.Capabilities.<Name>.Http   (HTTP-based implementation)
└── Lattice.Capabilities.<Name>.Stub   (test/dev implementation)
```

### Available Capabilities

| Capability | Behaviour | Live Implementation | Purpose |
|-----------|-----------|---------------------|---------|
| Sprites | `Lattice.Capabilities.Sprites` | `.Live` | Interact with the Sprites API (list, wake, sleep, exec) |
| GitHub | `Lattice.Capabilities.GitHub` | `.Http` | GitHub issues, labels, comments for HITL workflows |
| Fly | `Lattice.Capabilities.Fly` | `.Live` | Fly.io operations (logs, status, deploy) |
| Secret Store | `Lattice.Capabilities.SecretStore` | `.Env` | Secure credential access |

The GitHub capability uses `GitHub.Http` (direct HTTP API calls via `:httpc`) rather than the `gh` CLI, so it works in any environment including Fly.io containers.

### Auto-Selection

Capabilities are automatically selected at runtime based on available credentials:

```elixir
# In config/runtime.exs
capabilities =
  if System.get_env("SPRITES_API_TOKEN") do
    Keyword.put(capabilities, :sprites, Lattice.Capabilities.Sprites.Live)
  else
    capabilities  # falls back to stub
  end
```

## Intent Pipeline

The Intent system provides structured governance over all actions:

```
Observation → Intent proposed → Classify → Gate → Execute → Audit
                                              ↓
                                    Await approval (if needed)
```

See the [Intents](/lattice/concepts/intents/) concept page for full details.

## Authentication

Lattice uses Clerk for authentication with GitHub OAuth:

- **Login** -- operators visit `/login`, sign in with GitHub via Clerk's hosted UI
- **Session** -- Clerk JS obtains a JWT, POSTs it to `/auth/callback`, which verifies the token and creates a Phoenix session
- **Token verification** -- `Lattice.Auth.Clerk` verifies JWTs via Clerk's JWKS endpoint
- **GitHub token** -- `Lattice.Auth.ClerkGitHub` fetches the operator's GitHub OAuth token from Clerk's Backend API, enabling GitHub API calls on behalf of the operator

Required env vars: `CLERK_SECRET_KEY` (backend API), `CLERK_PUBLISHABLE_KEY` (frontend JS). Tests use a Mox mock (`Lattice.MockAuth`).

For the REST API, authentication uses bearer tokens via the `Authorization: Bearer <token>` header, validated by the `LatticeWeb.Plugs.Auth` plug.

For LiveView routes, authentication is enforced by the `LatticeWeb.Hooks.AuthHook` on mount, which redirects unauthenticated users to `/login`.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.18+ / OTP 27+ |
| Web | Phoenix 1.7+ / LiveView 1.0+ |
| Process model | GenServer, DynamicSupervisor, Registry |
| Events | `:telemetry` + Phoenix.PubSub |
| Persistence | ETS (intents), process state (sprites) |
| Auth | Bearer token (API) / Clerk (LiveView) |
| Deployment | Fly.io + Fly Scheduled Machines |
| CI | GitHub Actions |

## Design Principles

Lattice follows these core design principles (from [PHILOSOPHY.md](https://github.com/plattegruber/lattice/blob/main/PHILOSOPHY.md)):

1. **Walking Skeleton First** -- thinnest possible vertical slice that works end-to-end
2. **Observable by Default** -- every state change emits events, no hidden state
3. **Safe Boundaries** -- classify, gate, and audit every action
4. **Processes, Not Services** -- OTP is the runtime, not Kubernetes
5. **Events Are Truth** -- state changes flow through Telemetry and PubSub
6. **GitHub as Human Substrate** -- issues for approval workflows
7. **Minimal Persistence Early** -- ETS and process state first, PostgreSQL later
8. **Vertical PRs Only** -- every change ships as a complete vertical slice
