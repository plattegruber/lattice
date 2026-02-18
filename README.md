# Lattice

A Phoenix/LiveView control plane for managing AI coding agents (Sprites).

Lattice gives you a real-time operations dashboard for your fleet of Sprites — with human-in-the-loop safety via GitHub, capability-bounded access to external systems, and deployment on Fly.io.

## Architecture

```
Phoenix/LiveView (ops dashboard)
        │
   Fleet Manager (DynamicSupervisor)
        │
   ┌────┼────┐
Sprite Sprite Sprite  (GenServers — one per agent)
   │    │    │
   Capability Modules  (GitHub, Fly, Sprites API)
        │
   Telemetry + PubSub  (event-driven observability)
        │
   Safety & Guardrails  (classify → gate → audit)
```

**Key ideas:**

- Each Sprite is an OTP process (GenServer) that reconciles desired vs. actual state
- LiveView renders event projections — never polls
- Capabilities are behaviour modules — mockable, testable, swappable
- Every action is classified, gated, and audit-logged
- GitHub issues serve as the human-in-the-loop approval substrate

## Getting Started

```bash
# Prerequisites: Erlang/OTP 27+, Elixir 1.18+
mix setup
mix phx.server
# Visit http://localhost:4000
```

## Development

```bash
mix test                          # Run tests
mix format --check-formatted      # Check formatting
mix credo --strict                # Static analysis
mix compile --warnings-as-errors  # Strict compilation
```

See [CLAUDE.md](CLAUDE.md) for detailed conventions and [PHILOSOPHY.md](PHILOSOPHY.md) for design principles.

## API

Lattice exposes an authenticated JSON API under `/api`. All endpoints require a bearer token via the `Authorization: Bearer <token>` header.

**Response envelope:**

- Success: `{ "data": { ... }, "timestamp": "..." }`
- Error: `{ "error": "message", "code": "ERROR_CODE" }`

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/fleet` | Fleet summary (sprite counts by state) |
| `POST` | `/api/fleet/audit` | Trigger fleet-wide reconciliation audit |
| `GET` | `/api/sprites` | List all sprites with current state |
| `GET` | `/api/sprites/:id` | Single sprite detail |
| `POST` | `/api/sprites` | Create a sprite |
| `PUT` | `/api/sprites/:id/desired` | Update desired state (`ready` / `hibernating`) |
| `PUT` | `/api/sprites/:id/tags` | Update sprite tags/metadata |
| `DELETE` | `/api/sprites/:id` | Delete a sprite |
| `POST` | `/api/sprites/:id/reconcile` | Trigger reconciliation for one sprite |
| `POST` | `/api/sprites/:id/exec` | Start exec session |
| `GET` | `/api/sprites/:id/sessions` | List active exec sessions |
| `DELETE` | `/api/sprites/:id/sessions/:sid` | Terminate exec session |
| `GET` | `/api/intents` | List intents |
| `POST` | `/api/intents` | Create intent |
| `GET` | `/api/runs` | List runs |
| `GET` | `/api/runs/:id` | Run detail |

An unauthenticated `GET /health` endpoint is also available.

## Deployment

Deployed on [Fly.io](https://fly.io). See issue tracker for deployment setup status.

## License

All rights reserved.
