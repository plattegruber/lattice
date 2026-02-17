defmodule Lattice do
  @moduledoc """
  Lattice is an Elixir/Phoenix control plane for managing AI coding agents ("Sprites").

  It provides real-time fleet visibility, a Sprite-per-process model backed by
  GenServer and DynamicSupervisor, capability modules for external system
  integration, GitHub-based human-in-the-loop approval workflows, and a
  safety pipeline that classifies, gates, and audit-logs every action.

  ## Key Concepts

  - **Sprites** -- each Sprite is a GenServer managed by a Fleet Manager.
    See `Lattice.Sprites.Sprite` and `Lattice.Sprites.FleetManager`.

  - **Intents** -- the unit of work. Nothing happens without an Intent.
    See `Lattice.Intents.Intent` and `Lattice.Intents.Pipeline`.

  - **Capabilities** -- bounded behaviour modules for external systems
    (GitHub, Fly.io, Sprites API). See `Lattice.Capabilities`.

  - **Safety** -- action classification, gating, and audit logging.
    See `Lattice.Safety.Classifier`, `Lattice.Safety.Gate`, and `Lattice.Safety.Audit`.

  - **Events** -- Telemetry + PubSub event bus. LiveView subscribes and
    renders projections. No polling. See `Lattice.Events`.

  ## Architecture

      Phoenix/LiveView  (Fleet Dashboard, Sprite Detail, Approvals Queue)
            |
      Fleet Manager     (DynamicSupervisor, Registry)
            |
      Sprite GenServers (one per Sprite)
            |
      Capability Modules (GitHub, Fly, Sprites API)
            |
      Telemetry + PubSub (Event Bus)
            |
      Safety & Guardrails (Classify, Gate, Audit)
  """
end
