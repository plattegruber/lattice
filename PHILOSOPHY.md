# Philosophy — Lattice

This document captures the design principles and product thinking behind Lattice. Read this before writing code.

## What We're Building

A **control plane for AI coding agents**. Not an AI framework. Not a chatbot. An operations tool that lets a human operator manage a fleet of Sprites — the way a NOC engineer manages a fleet of servers.

The operator sees what each Sprite is doing, can intervene when needed, and trusts that unsafe actions will be caught before they execute.

## Core Principles

### 1. Walking Skeleton First

Build the thinnest possible vertical slice that works end-to-end before adding depth. A Sprite process that emits synthetic events, rendered in a LiveView dashboard, is more valuable than a perfect API client with no UI.

### 2. Observable by Default

Every state change emits a Telemetry event. Every event flows through PubSub. LiveView subscribes and renders. There is no hidden state — if it happened, you can see it.

This is the "NOC glass" mental model: the dashboard should tell you what's happening right now without clicking into anything.

### 3. Safe Boundaries

Full computer access is the magic of Sprites. Safety is non-negotiable.

- Every action is **classified** (safe / needs-review / dangerous)
- Dangerous actions are **gated** until a human approves via GitHub
- Every action, approved or not, is **audit-logged**
- Capabilities are **behaviour modules** — bounded interfaces, not open shell access

### 4. Processes, Not Services

OTP is the runtime. Each Sprite is a GenServer. The Fleet Manager is a DynamicSupervisor. State lives in processes, supervised by the BEAM.

We don't need Kubernetes, message queues, or microservices. We need `GenServer.start_link/3`.

### 5. Events Are Truth

State changes are communicated via Telemetry events and PubSub broadcasts. LiveView renders projections of event streams. The database (when we add one) is a projection too.

This means:
- No polling. Ever.
- No "refresh the page to see changes."
- The dashboard is always live.

### 6. GitHub as Human Substrate

GitHub issues are the approval interface for human-in-the-loop workflows. Not Slack. Not email. Not a custom UI.

Why GitHub:
- Operators already live there
- Issues have comments, labels, assignees — a natural approval workflow
- Everything is versioned and auditable
- Sprites can read and write issues via API

### 7. Minimal Persistence Early

ETS and process state first. PostgreSQL later, only when we need it. Don't add a database until the pain of not having one is concrete.

### 8. Vertical PRs Only

Every change ships as a complete vertical slice. No "backend PR" followed by "frontend PR." Each PR should boot, work, and be testable on its own.

## What We're Not Building

- **An AI framework.** We don't run models. Sprites run themselves. We observe and manage them.
- **A chatbot interface.** The operator uses a dashboard, not a chat window.
- **Multi-tenant SaaS.** Each Lattice instance manages one fleet. Multi-instance is fine; multi-tenant is not a goal.
- **A CI/CD system.** We trigger and observe. We don't replace GitHub Actions or Fly deployments.

## Design Taste

- **Boring technology.** Phoenix, LiveView, GenServer, PostgreSQL. No novel infrastructure.
- **Small surface area.** Fewer features, well-built. Resist the urge to add configuration options.
- **Show, don't tell.** The dashboard should make state obvious. Minimize text explanations; maximize real-time visibility.
- **Fail loudly.** Crashes are fine — supervisors restart things. Silent failures are not fine.
