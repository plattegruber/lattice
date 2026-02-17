---
title: Safety & Guardrails
description: How Lattice classifies, gates, and audits every action to ensure safe operation.
---

Safety is a first-class concern in Lattice. Every action flows through a **classify-gate-audit** pipeline that ensures nothing happens without appropriate oversight. This is the enforcement mechanism for the "Safe Boundaries" design principle.

## The Pipeline

```
Action proposed → Classify → Gate → Execute (or deny)
                                        ↓
                                   Audit (always)
```

Every action -- whether allowed or denied, successful or failed -- is audit-logged.

## Classification

The **Classifier** maps `{capability, operation}` pairs to one of three safety levels:

### Safe

Read-only operations with no side effects. These never modify state or trigger side effects in external systems.

| Capability | Operation |
|-----------|-----------|
| `sprites` | `list_sprites`, `get_sprite`, `fetch_logs` |
| `github` | `list_issues`, `get_issue` |
| `fly` | `logs`, `machine_status` |
| `secret_store` | `get_secret` |

### Controlled

Operations that mutate state in a bounded way. They change the state of a single resource but do not affect infrastructure.

| Capability | Operation |
|-----------|-----------|
| `sprites` | `wake`, `sleep`, `exec` |
| `github` | `create_issue`, `update_issue`, `add_label`, `remove_label`, `create_comment` |

### Dangerous

Operations with infrastructure-level impact. These require both a configuration opt-in and human approval.

| Capability | Operation |
|-----------|-----------|
| `fly` | `deploy` |

Unknown operations (not registered in the Classifier) default to `:controlled` for safety.

## Gating Rules

The **Gate** decides whether a classified action is allowed to execute:

| Classification | Config Required | Approval Required |
|----------------|----------------|-------------------|
| SAFE | none | none |
| CONTROLLED | `allow_controlled: true` | if `require_approval_for_controlled: true` |
| DANGEROUS | `allow_dangerous: true` | always |

### Configuration

Guardrails are configured in `config/config.exs`:

```elixir
config :lattice, :guardrails,
  allow_controlled: true,
  allow_dangerous: false,
  require_approval_for_controlled: true
```

- **`allow_controlled`** -- when `false`, all controlled actions are denied outright
- **`allow_dangerous`** -- when `false`, all dangerous actions are denied outright (default)
- **`require_approval_for_controlled`** -- when `true`, controlled actions need human approval before execution

### Gate Decisions

The Gate returns one of three outcomes:

- `:allow` -- action can proceed immediately
- `{:deny, :approval_required}` -- action is permitted but needs human approval first
- `{:deny, :action_not_permitted}` -- action category is disabled in configuration

```elixir
{:ok, action} = Classifier.classify(:sprites, :wake)

case Gate.check(action) do
  :allow ->
    # Execute immediately

  {:deny, :approval_required} ->
    # Create GitHub issue for approval
    # Wait for human to add "approved" label

  {:deny, :action_not_permitted} ->
    # Reject -- this action category is disabled
end
```

## Approval Workflow

When an action requires approval, Lattice creates a GitHub issue in the configured repository. The operator reviews the proposed action and either:

1. **Approves** -- adds the `approved` label to the GitHub issue
2. **Rejects** -- the intent transitions to `:rejected`

The approval check polls for the `approved` label on the GitHub issue. Only after the label is present can the action proceed.

This is the **human-in-the-loop (HITL)** pattern: GitHub issues serve as the approval substrate because operators already live in GitHub. Issues have comments, labels, assignees -- a natural approval workflow.

### Approval Flow

```
Intent proposed
    → Classified as CONTROLLED or DANGEROUS
    → Gate returns {:deny, :approval_required}
    → GitHub issue created with proposal details
    → Intent moves to :awaiting_approval
    → Human reviews and adds "approved" label
    → Intent advances to :approved
    → Execution proceeds
```

## Audit Logging

The **Audit** module logs every capability invocation:

1. Creates an `%AuditEntry{}` struct with full context
2. Emits a `[:lattice, :safety, :audit]` Telemetry event
3. Broadcasts the entry via PubSub on the `"safety:audit"` topic

### What Gets Logged

Every audit entry captures:

- **Capability** -- which external system (`sprites`, `github`, `fly`, `secret_store`)
- **Operation** -- what function was called
- **Classification** -- the safety level
- **Result** -- `:ok`, `{:error, reason}`, or `:denied`
- **Actor** -- who initiated (`:system`, `:human`, `:scheduled`)
- **Arguments** -- sanitized to redact secrets
- **Operator** -- the authenticated operator (when available)
- **Timestamp** -- when the action occurred

### Argument Sanitization

Arguments are sanitized before logging to prevent secrets from appearing in audit trails. Map arguments have sensitive keys (`token`, `password`, `secret`, `key`, `api_key`, `access_token`) replaced with `"[REDACTED]"`.

```elixir
Audit.sanitize_args([%{token: "secret123", name: "atlas"}])
# => [%{token: "[REDACTED]", name: "atlas"}]
```

### Viewing Audit Logs

Audit entries are visible in the [Incidents view](/lattice/guides/dashboard/#incidents-view-incidents) of the dashboard, streamed in real time via PubSub.
