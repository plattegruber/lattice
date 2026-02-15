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

## Deployment

Deployed on [Fly.io](https://fly.io). See issue tracker for deployment setup status.

## License

Private.
