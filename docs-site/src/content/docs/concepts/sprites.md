---
title: Sprites
description: Understanding the Sprite process model -- GenServers that represent AI coding agents.
---

A **Sprite** is the core abstraction in Lattice. Each Sprite represents a single AI coding agent, modeled as an OTP GenServer process. Sprites are managed by the [Fleet Manager](/lattice/concepts/fleet-manager/) and supervised by a DynamicSupervisor.

## Sprite as Process

Every Sprite gets its own GenServer that:

- **Owns its state** -- an internal `%Lattice.Sprites.State{}` struct tracking desired vs. observed state
- **Runs a reconciliation loop** -- periodically compares desired state against real observed state from the Sprites API
- **Emits events** -- Telemetry events and PubSub broadcasts on every state transition
- **Handles backoff** -- exponential backoff with jitter on reconciliation failures
- **Computes health** -- broadcasts health assessments after each reconciliation cycle

```
┌─────────────────────────────────────────┐
│            Sprite GenServer             │
│                                         │
│  desired_state: :ready                  │
│  observed_state: :hibernating           │
│  health: :converging                    │
│  failure_count: 0                       │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │      Reconciliation Loop         │  │
│  │  fetch observed → compare →      │  │
│  │  transition if needed → emit     │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

## Lifecycle States

Each Sprite has both a **desired state** (what you want) and an **observed state** (what the API reports). The reconciliation loop drives observed toward desired.

| State | Meaning |
|-------|---------|
| `:hibernating` | Sprite is cold/sleeping, not consuming resources |
| `:waking` | Sprite is warming up, transitioning to ready |
| `:ready` | Sprite is running and available for work |
| `:busy` | Sprite is actively executing a task |
| `:error` | Sprite is in an error state (reconciliation failures) |

### State Transitions

```
hibernating ──wake──→ waking ──warm──→ ready ──task──→ busy
     ↑                                  │               │
     └──────────sleep──────────────────┘               │
     ↑                                                  │
     └──────────────sleep──────────────────────────────┘

Any state → error (on max retries exceeded)
error → waking (recovery attempt)
```

## Starting a Sprite

Sprites are started through the Fleet Manager, which reads from configuration:

```elixir
config :lattice, :fleet,
  sprites: [
    %{id: "sprite-001", desired_state: :hibernating},
    %{id: "sprite-002", desired_state: :ready}
  ]
```

You can also interact with sprites directly via the GenServer API:

```elixir
# Get current state
{:ok, state} = Lattice.Sprites.Sprite.get_state(pid)

# Change desired state
:ok = Lattice.Sprites.Sprite.set_desired_state(pid, :ready)

# Force immediate reconciliation
Lattice.Sprites.Sprite.reconcile_now(pid)
```

## Reconciliation

The reconciliation loop runs on a configurable interval (default: 5 seconds). Each cycle:

1. **Fetch** -- calls the Sprites API to get the real observed state
2. **Compare** -- checks if observed matches desired
3. **Act** -- if they differ, calls the appropriate capability to drive the transition (e.g., `wake/1`, `sleep/1`)
4. **Emit** -- publishes a `ReconciliationResult` event with the outcome
5. **Health** -- computes and broadcasts a health assessment

### Backoff on Failure

When reconciliation fails, the Sprite applies exponential backoff with jitter:

- Base backoff starts at 1 second (configurable)
- Each consecutive failure doubles the delay, up to a maximum (default: 60 seconds)
- Jitter prevents thundering herd when multiple sprites fail simultaneously
- On success, the backoff resets to the normal interval

### Health Assessment

Health is computed from the reconciliation state:

| Health | Condition |
|--------|-----------|
| `:ok` | Observed matches desired |
| `:converging` | Action taken, waiting for effect |
| `:degraded` | Retrying after consecutive failures |
| `:error` | Max retries exceeded |

## Observations

Sprites can emit **Observations** -- structured facts about the world they have noticed. Observations represent reality without side effects:

```elixir
Lattice.Sprites.Sprite.emit_observation(pid,
  type: :metric,
  data: %{"cpu" => 85.2, "memory_mb" => 512},
  severity: :medium
)
```

Observation types:

- `:metric` -- quantitative measurements (CPU, memory, latency)
- `:anomaly` -- something unexpected detected
- `:status` -- current state or health of a resource
- `:recommendation` -- a suggested improvement or action

Observations feed the [Intent pipeline](/lattice/concepts/intents/) by generating proposals when conditions warrant action.

## API Status Mapping

The Sprites API returns string statuses that Lattice maps to internal lifecycle atoms:

| API Status | Internal State |
|-----------|---------------|
| `"running"` | `:ready` |
| `"cold"` | `:hibernating` |
| `"warm"` | `:waking` |
| `"sleeping"` | `:hibernating` |
