# AGENTS.md — Lattice

Guidelines for AI agents working on this repository.

## Required Reading

1. [PHILOSOPHY.md](PHILOSOPHY.md) — design principles and product thinking
2. [CLAUDE.md](CLAUDE.md) — architecture, conventions, and commands

## Project Overview

Lattice is an Elixir/Phoenix control plane for managing AI coding agents (Sprites). It uses OTP processes (GenServer per Sprite), LiveView for real-time dashboards, and capability behaviours for safe, bounded access to external systems.

## Build & Test Commands

```bash
mix setup                         # Bootstrap project
mix test                          # Run all tests
mix test --only unit              # Unit tests only
mix format --check-formatted      # Check formatting
mix credo --strict                # Static analysis
mix compile --warnings-as-errors  # Strict compilation
```

## Coding Style

- Elixir with standard library conventions
- 2-space indentation (Elixir default)
- `mix format` enforced
- Pattern matching over conditionals
- Structs for domain types
- Behaviours for external dependencies

## Testing

- ExUnit with Mox for behaviour mocking
- Tests colocated in `test/` mirroring `lib/` structure
- `@tag :unit` and `@tag :integration` for categorization

## Commits & PRs

- Imperative mood: "Add fleet dashboard", not "Added fleet dashboard"
- Each PR is a complete vertical slice
- Small, focused PRs preferred
