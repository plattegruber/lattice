# Code Review Guidelines — Lattice

Use these guidelines when reviewing PRs (automated or manual).

## Highest Priority: Vertical Slice Completeness

Every PR must be a complete vertical slice. Check:

- [ ] Feature works end-to-end (not just backend or just frontend)
- [ ] Tests cover the new behavior
- [ ] No manual steps required post-merge
- [ ] LiveView updates in real-time (no polling patterns)
- [ ] Telemetry events emitted for state changes

## Architecture

- **Capabilities are behaviours.** External system access must go through a behaviour module, never direct API calls in business logic.
- **GenServer state is a struct.** No bare maps for Sprite or Fleet state.
- **Events flow through PubSub.** LiveView subscribes in `mount`, never polls.
- **Safety is enforced.** Actions touching external systems must be classified and gated.
- **Contexts own business logic.** Controllers and LiveViews delegate — they don't compute.

## Code Conventions

- Elixir formatter applied (`mix format`)
- No compiler warnings (`--warnings-as-errors`)
- Credo clean (`mix credo --strict`)
- Pattern matching in function heads preferred over `if`/`case` in body
- Pipe chains read clearly top-to-bottom
- Domain types use structs, not bare maps

## Testing

- Test public module APIs, not internal functions
- Use Mox for capability behaviour mocks
- Tag tests: `@tag :unit`, `@tag :integration`
- No tests that depend on external services without mocking

## What to Flag

- **Bug:** Incorrect behavior, race conditions, missing error handling at system boundaries
- **Security:** Unsanitized input, missing auth checks, secrets in code
- **Design:** Violates capability boundary, polling instead of PubSub, business logic in LiveView
- **Style:** Formatting, naming, unnecessary complexity
