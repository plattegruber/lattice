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

## Prerequisites

- Erlang/OTP 27+
- Elixir 1.18+

We recommend [asdf](https://asdf-vm.com/) to manage versions. The `.tool-versions` file pins exact versions.

## Getting Started

```bash
mix setup              # Install deps + build assets
mix phx.server         # Start dev server at http://localhost:4000
iex -S mix phx.server  # Start with IEx shell attached
```

## Development

```bash
mix test                          # Run tests
mix format --check-formatted      # Check formatting
mix compile --warnings-as-errors  # Strict compilation
```

## API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check — returns `{"status": "ok"}` |

## Deployment

Deployed on [Fly.io](https://fly.io). Pushes to `main` trigger CI, then auto-deploy.

```bash
fly deploy          # Manual deploy
fly logs            # Tail production logs
```

Set the `FLY_API_TOKEN` secret in GitHub Actions for automated deploys.

See [CLAUDE.md](CLAUDE.md) for detailed conventions and [PHILOSOPHY.md](PHILOSOPHY.md) for design principles.

## License

Private.
