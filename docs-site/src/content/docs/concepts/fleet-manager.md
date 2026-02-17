---
title: Fleet Manager
description: How the Fleet Manager coordinates Sprite lifecycle and provides fleet-wide operations.
---

The **Fleet Manager** is the central coordinator for all Sprite processes. It is a GenServer responsible for discovering sprites from configuration, starting their processes, and providing fleet-wide query and control operations.

## Supervision Tree

The Fleet Manager operates within this supervision structure:

```
Application Supervisor
├── Lattice.Sprites.Registry       (process lookup by sprite_id)
├── Lattice.Sprites.DynamicSupervisor  (supervises individual Sprites)
└── Lattice.Sprites.FleetManager   (discovery + coordination)
```

- **Registry** -- an Elixir `Registry` that maps sprite IDs to PIDs, enabling `via` tuple addressing
- **DynamicSupervisor** -- supervises each Sprite GenServer, restarting them on crash
- **FleetManager** -- reads configuration, starts sprites, provides fleet-wide operations

## Discovery

On startup, the Fleet Manager reads the configured sprite list and starts a GenServer for each one:

```elixir
config :lattice, :fleet,
  sprites: [
    %{id: "sprite-001", desired_state: :hibernating},
    %{id: "sprite-002", desired_state: :ready},
    %{id: "sprite-003", desired_state: :hibernating}
  ]
```

Each sprite is started as a child of the DynamicSupervisor with its configured desired state.

## Fleet Operations

### Querying the Fleet

```elixir
# List all sprites with their current state
sprites = FleetManager.list_sprites()
# => [{"sprite-001", %State{...}}, {"sprite-002", %State{...}}]

# Get a fleet summary (counts by state)
summary = FleetManager.fleet_summary()
# => %{total: 3, by_state: %{hibernating: 2, ready: 1}}

# Look up a specific sprite's process
{:ok, pid} = FleetManager.get_sprite_pid("sprite-001")
```

### Controlling the Fleet

```elixir
# Wake specific sprites (set desired state to :ready)
results = FleetManager.wake_sprites(["sprite-001", "sprite-003"])
# => %{"sprite-001" => :ok, "sprite-003" => :ok}

# Put sprites to sleep (set desired state to :hibernating)
results = FleetManager.sleep_sprites(["sprite-002"])
# => %{"sprite-002" => :ok}

# Trigger fleet-wide reconciliation audit
:ok = FleetManager.run_audit()
```

### Fleet Audit

The `run_audit/0` function triggers an immediate reconciliation cycle on every managed sprite. This is useful for:

- Verifying all sprites match their desired state after a deployment
- Recovery from infrastructure events
- Periodic health checks via [Scheduled Machines](/lattice/guides/deployment/#scheduled-machines)

A Mix task (`mix lattice.audit`) and a REST API endpoint (`POST /api/fleet/audit`) also trigger fleet audits.

## Events

After every fleet-mutating operation, the Fleet Manager:

1. Computes a fresh fleet summary (total count + breakdown by observed state)
2. Emits a `[:lattice, :fleet, :summary]` Telemetry event
3. Broadcasts `{:fleet_summary, summary}` on the `"sprites:fleet"` PubSub topic

The [Dashboard](/lattice/guides/dashboard/) subscribes to this topic and updates in real time.

## Process Addressing

Individual sprites can be addressed by their ID using the Registry:

```elixir
# Via tuple for addressing a sprite by ID
Lattice.Sprites.Sprite.via("sprite-001")
# => {:via, Registry, {Lattice.Sprites.Registry, "sprite-001"}}

# Use it to query state
{:ok, state} = Lattice.Sprites.Sprite.get_state(Sprite.via("sprite-001"))
```

This lets you interact with any sprite without holding a reference to its PID.
