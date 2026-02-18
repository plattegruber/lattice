defmodule LatticeWeb.Schemas do
  @moduledoc """
  OpenAPI schema definitions for the Lattice REST API.

  Each nested module defines one reusable schema via `OpenApiSpex.schema/1`.
  Controllers reference these schemas in their `operation/2` specs.
  """

  alias OpenApiSpex.Schema

  # ── Error Responses ──────────────────────────────────────────────

  defmodule ErrorResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Standard error envelope returned by all endpoints on failure.",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Human-readable error message"},
        code: %Schema{
          type: :string,
          description: "Machine-readable error code",
          enum: [
            "SPRITE_NOT_FOUND",
            "INTENT_NOT_FOUND",
            "MISSING_FIELD",
            "INVALID_STATE",
            "INVALID_KIND",
            "INVALID_SOURCE_TYPE",
            "INVALID_STATE_TRANSITION",
            "INVALID_TRANSITION",
            "SPRITE_ALREADY_EXISTS",
            "UPSTREAM_API_ERROR",
            "DELETE_FAILED"
          ]
        }
      },
      required: [:error, :code],
      example: %{
        "error" => "Sprite not found",
        "code" => "SPRITE_NOT_FOUND"
      }
    })
  end

  defmodule UnauthorizedResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "UnauthorizedResponse",
      description: "Returned when the Authorization header is missing or invalid.",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Error message"}
      },
      required: [:error],
      example: %{
        "error" => "Missing or invalid authorization"
      }
    })
  end

  # ── Health ───────────────────────────────────────────────────────

  defmodule InstanceIdentity do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "InstanceIdentity",
      description: "Instance metadata included in health checks.",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Instance name"},
        environment: %Schema{type: :string, description: "Runtime environment"},
        resources: %Schema{
          type: :object,
          description: "Bound resource identifiers (secrets redacted)",
          additionalProperties: %Schema{type: :string, nullable: true}
        }
      },
      example: %{
        "name" => "lattice-dev",
        "environment" => "dev",
        "resources" => %{
          "github_repo" => "plattegruber/lattice",
          "fly_org" => "lattice-org"
        }
      }
    })
  end

  defmodule HealthResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      description: "Health check response.",
      type: :object,
      properties: %{
        status: %Schema{type: :string, description: "Service status", enum: ["ok"]},
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"},
        instance: LatticeWeb.Schemas.InstanceIdentity
      },
      required: [:status, :timestamp, :instance],
      example: %{
        "status" => "ok",
        "timestamp" => "2026-01-15T12:00:00Z",
        "instance" => %{
          "name" => "lattice-dev",
          "environment" => "dev",
          "resources" => %{}
        }
      }
    })
  end

  # ── Fleet ────────────────────────────────────────────────────────

  defmodule FleetSummary do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "FleetSummary",
      description: "Fleet-wide summary with sprite counts by state.",
      type: :object,
      properties: %{
        total: %Schema{type: :integer, description: "Total number of sprites in the fleet"},
        by_state: %Schema{
          type: :object,
          description: "Sprite count grouped by observed state",
          additionalProperties: %Schema{type: :integer}
        }
      },
      required: [:total, :by_state],
      example: %{
        "total" => 5,
        "by_state" => %{"ready" => 3, "hibernating" => 2}
      }
    })
  end

  defmodule FleetSummaryResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "FleetSummaryResponse",
      description: "Fleet summary response envelope.",
      type: :object,
      properties: %{
        data: LatticeWeb.Schemas.FleetSummary,
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end

  defmodule AuditTriggeredResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "AuditTriggeredResponse",
      description: "Response after triggering a fleet-wide audit.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            status: %Schema{type: :string, enum: ["audit_triggered"]}
          },
          required: [:status]
        },
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp],
      example: %{
        "data" => %{"status" => "audit_triggered"},
        "timestamp" => "2026-01-15T12:00:00Z"
      }
    })
  end

  # ── Sprites ──────────────────────────────────────────────────────

  defmodule SpriteSummary do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SpriteSummary",
      description: "Abbreviated sprite representation used in list responses.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Sprite identifier"},
        observed_state: %Schema{
          type: :string,
          description: "Current observed lifecycle state",
          enum: ["hibernating", "waking", "ready", "busy", "error"]
        },
        desired_state: %Schema{
          type: :string,
          description: "Operator-set target state",
          enum: ["hibernating", "waking", "ready", "busy", "error"]
        },
        health: %Schema{
          type: :string,
          description: "Current health status",
          enum: ["ok", "converging", "degraded", "error", "healthy", "unhealthy", "unknown"]
        }
      },
      required: [:id, :observed_state, :desired_state, :health],
      example: %{
        "id" => "sprite-abc123",
        "observed_state" => "ready",
        "desired_state" => "ready",
        "health" => "ok"
      }
    })
  end

  defmodule SpriteDetail do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SpriteDetail",
      description: "Full sprite representation with timestamps and failure tracking.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Sprite identifier"},
        observed_state: %Schema{
          type: :string,
          description: "Current observed lifecycle state",
          enum: ["hibernating", "waking", "ready", "busy", "error"]
        },
        desired_state: %Schema{
          type: :string,
          description: "Operator-set target state",
          enum: ["hibernating", "waking", "ready", "busy", "error"]
        },
        health: %Schema{
          type: :string,
          description: "Current health status",
          enum: ["ok", "converging", "degraded", "error", "healthy", "unhealthy", "unknown"]
        },
        failure_count: %Schema{
          type: :integer,
          description: "Number of consecutive failures"
        },
        last_observed_at: %Schema{
          type: :string,
          format: :datetime,
          nullable: true,
          description: "When the sprite was last observed"
        },
        started_at: %Schema{
          type: :string,
          format: :datetime,
          description: "When the sprite process started"
        },
        updated_at: %Schema{
          type: :string,
          format: :datetime,
          description: "When the sprite state was last updated"
        },
        tags: %Schema{
          type: :object,
          description: "Lattice-local metadata tags (key-value pairs)",
          additionalProperties: %Schema{type: :string}
        }
      },
      required: [:id, :observed_state, :desired_state, :health],
      example: %{
        "id" => "sprite-abc123",
        "observed_state" => "ready",
        "desired_state" => "ready",
        "health" => "ok",
        "failure_count" => 0,
        "last_observed_at" => "2026-01-15T12:00:00Z",
        "started_at" => "2026-01-15T11:00:00Z",
        "updated_at" => "2026-01-15T12:00:00Z",
        "tags" => %{"env" => "prod"}
      }
    })
  end

  defmodule SpriteListResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SpriteListResponse",
      description: "List of sprites response envelope.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: LatticeWeb.Schemas.SpriteSummary,
          description: "Array of sprite summaries"
        },
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end

  defmodule SpriteDetailResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SpriteDetailResponse",
      description: "Single sprite detail response envelope.",
      type: :object,
      properties: %{
        data: LatticeWeb.Schemas.SpriteDetail,
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end

  defmodule UpdateDesiredStateRequest do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "UpdateDesiredStateRequest",
      description: "Request body for updating a sprite's desired state.",
      type: :object,
      properties: %{
        state: %Schema{
          type: :string,
          description: "Target desired state",
          enum: ["ready", "hibernating"]
        }
      },
      required: [:state],
      example: %{
        "state" => "ready"
      }
    })
  end

  defmodule CreateSpriteRequest do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "CreateSpriteRequest",
      description: "Request body for creating a new sprite.",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          description: "Name for the new sprite"
        }
      },
      required: [:name],
      example: %{
        "name" => "my-sprite"
      }
    })
  end

  defmodule DeleteSpriteResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DeleteSpriteResponse",
      description: "Response after deleting a sprite.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, description: "The deleted sprite's identifier"},
            deleted: %Schema{type: :boolean, description: "Whether the sprite was deleted"}
          },
          required: [:id, :deleted]
        },
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp],
      example: %{
        "data" => %{
          "id" => "sprite-abc123",
          "deleted" => true
        },
        "timestamp" => "2026-01-15T12:00:00Z"
      }
    })
  end

  defmodule UpdateTagsRequest do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "UpdateTagsRequest",
      description: "Request body for updating a sprite's tags.",
      type: :object,
      properties: %{
        tags: %Schema{
          type: :object,
          description: "Key-value map of tags to merge into existing tags",
          additionalProperties: %Schema{type: :string}
        }
      },
      required: [:tags],
      example: %{
        "tags" => %{"env" => "prod", "purpose" => "ci-runner"}
      }
    })
  end

  defmodule UpdateTagsResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "UpdateTagsResponse",
      description: "Response after updating a sprite's tags.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, description: "Sprite identifier"},
            tags: %Schema{
              type: :object,
              description: "The merged tags map",
              additionalProperties: %Schema{type: :string}
            }
          },
          required: [:id, :tags]
        },
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp],
      example: %{
        "data" => %{
          "id" => "sprite-abc123",
          "tags" => %{"env" => "prod", "purpose" => "ci-runner"}
        },
        "timestamp" => "2026-01-15T12:00:00Z"
      }
    })
  end

  defmodule ReconcileTriggeredResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ReconcileTriggeredResponse",
      description: "Response after triggering sprite reconciliation.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            sprite_id: %Schema{type: :string, description: "The sprite that was reconciled"},
            status: %Schema{type: :string, enum: ["reconciliation_triggered"]}
          },
          required: [:sprite_id, :status]
        },
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp],
      example: %{
        "data" => %{
          "sprite_id" => "sprite-abc123",
          "status" => "reconciliation_triggered"
        },
        "timestamp" => "2026-01-15T12:00:00Z"
      }
    })
  end

  # ── Intents ──────────────────────────────────────────────────────

  defmodule IntentSource do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntentSource",
      description: "The originator of an intent.",
      type: :object,
      properties: %{
        type: %Schema{
          type: :string,
          description: "Source type",
          enum: ["sprite", "agent", "cron", "operator"]
        },
        id: %Schema{type: :string, description: "Source identifier"}
      },
      required: [:type, :id],
      example: %{
        "type" => "sprite",
        "id" => "sprite-abc123"
      }
    })
  end

  defmodule TransitionEntry do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "TransitionEntry",
      description: "A single state transition in the intent lifecycle.",
      type: :object,
      properties: %{
        from: %Schema{type: :string, description: "Previous state"},
        to: %Schema{type: :string, description: "New state"},
        timestamp: %Schema{
          type: :string,
          format: :datetime,
          description: "When the transition occurred"
        },
        actor: %Schema{type: :string, nullable: true, description: "Who triggered the transition"},
        reason: %Schema{
          type: :string,
          nullable: true,
          description: "Reason for the transition"
        }
      },
      required: [:from, :to, :timestamp],
      example: %{
        "from" => "proposed",
        "to" => "classified",
        "timestamp" => "2026-01-15T12:00:00Z",
        "actor" => "system",
        "reason" => nil
      }
    })
  end

  defmodule IntentSummary do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntentSummary",
      description: "Abbreviated intent representation used in list responses.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Intent identifier"},
        kind: %Schema{
          type: :string,
          description: "Intent kind",
          enum: ["action", "inquiry", "maintenance"]
        },
        state: %Schema{
          type: :string,
          description: "Current lifecycle state",
          enum: [
            "proposed",
            "classified",
            "awaiting_approval",
            "approved",
            "running",
            "completed",
            "failed",
            "rejected",
            "canceled"
          ]
        },
        source: LatticeWeb.Schemas.IntentSource,
        summary: %Schema{type: :string, description: "Human-readable summary"},
        classification: %Schema{
          type: :string,
          nullable: true,
          description: "Safety classification",
          enum: ["safe", "controlled", "dangerous"]
        },
        inserted_at: %Schema{
          type: :string,
          format: :datetime,
          description: "When the intent was created"
        },
        updated_at: %Schema{
          type: :string,
          format: :datetime,
          description: "When the intent was last updated"
        }
      },
      required: [:id, :kind, :state, :source, :summary, :inserted_at, :updated_at],
      example: %{
        "id" => "intent-abc123",
        "kind" => "action",
        "state" => "proposed",
        "source" => %{"type" => "sprite", "id" => "sprite-abc123"},
        "summary" => "Deploy new version of the application",
        "classification" => nil,
        "inserted_at" => "2026-01-15T12:00:00Z",
        "updated_at" => "2026-01-15T12:00:00Z"
      }
    })
  end

  defmodule IntentDetail do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntentDetail",
      description: "Full intent representation with payload, metadata, and transition history.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Intent identifier"},
        kind: %Schema{
          type: :string,
          description: "Intent kind",
          enum: ["action", "inquiry", "maintenance"]
        },
        state: %Schema{
          type: :string,
          description: "Current lifecycle state",
          enum: [
            "proposed",
            "classified",
            "awaiting_approval",
            "approved",
            "running",
            "completed",
            "failed",
            "rejected",
            "canceled"
          ]
        },
        source: LatticeWeb.Schemas.IntentSource,
        summary: %Schema{type: :string, description: "Human-readable summary"},
        payload: %Schema{
          type: :object,
          description: "Intent-specific payload data",
          additionalProperties: true
        },
        classification: %Schema{
          type: :string,
          nullable: true,
          description: "Safety classification",
          enum: ["safe", "controlled", "dangerous"]
        },
        result: %Schema{
          type: :object,
          nullable: true,
          description: "Execution result (if completed or failed)",
          additionalProperties: true
        },
        metadata: %Schema{
          type: :object,
          nullable: true,
          description: "Arbitrary metadata",
          additionalProperties: true
        },
        affected_resources: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Resources affected by this intent"
        },
        expected_side_effects: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Expected side effects"
        },
        rollback_strategy: %Schema{
          type: :string,
          nullable: true,
          description: "Rollback strategy if the intent fails"
        },
        transition_log: %Schema{
          type: :array,
          items: LatticeWeb.Schemas.TransitionEntry,
          description: "Full state transition history"
        },
        inserted_at: %Schema{
          type: :string,
          format: :datetime,
          description: "When the intent was created"
        },
        updated_at: %Schema{
          type: :string,
          format: :datetime,
          description: "When the intent was last updated"
        },
        classified_at: %Schema{
          type: :string,
          format: :datetime,
          nullable: true,
          description: "When the intent was classified"
        },
        approved_at: %Schema{
          type: :string,
          format: :datetime,
          nullable: true,
          description: "When the intent was approved"
        },
        started_at: %Schema{
          type: :string,
          format: :datetime,
          nullable: true,
          description: "When execution started"
        },
        completed_at: %Schema{
          type: :string,
          format: :datetime,
          nullable: true,
          description: "When execution completed"
        }
      },
      required: [:id, :kind, :state, :source, :summary, :inserted_at, :updated_at]
    })
  end

  defmodule IntentListResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntentListResponse",
      description: "List of intents response envelope.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: LatticeWeb.Schemas.IntentSummary,
          description: "Array of intent summaries"
        },
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end

  defmodule IntentDetailResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntentDetailResponse",
      description: "Single intent detail response envelope.",
      type: :object,
      properties: %{
        data: LatticeWeb.Schemas.IntentDetail,
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end

  defmodule IntentSummaryResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntentSummaryResponse",
      description: "Single intent summary response envelope (used after mutations).",
      type: :object,
      properties: %{
        data: LatticeWeb.Schemas.IntentSummary,
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end

  defmodule CreateIntentRequest do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "CreateIntentRequest",
      description: "Request body for proposing a new intent.",
      type: :object,
      properties: %{
        kind: %Schema{
          type: :string,
          description: "Intent kind",
          enum: ["action", "inquiry", "maintenance"]
        },
        source: LatticeWeb.Schemas.IntentSource,
        summary: %Schema{type: :string, description: "Human-readable summary of the intent"},
        payload: %Schema{
          type: :object,
          description: "Intent-specific payload data",
          additionalProperties: true
        },
        affected_resources: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Resources affected by this intent (action kind only)"
        },
        expected_side_effects: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Expected side effects (action kind only)"
        },
        rollback_strategy: %Schema{
          type: :string,
          nullable: true,
          description: "Rollback strategy if the intent fails (action kind only)"
        }
      },
      required: [:kind, :source],
      example: %{
        "kind" => "action",
        "source" => %{"type" => "sprite", "id" => "sprite-abc123"},
        "summary" => "Deploy new version of the application",
        "payload" => %{"version" => "1.2.3"},
        "affected_resources" => ["fly-app:lattice"],
        "expected_side_effects" => ["app restart"],
        "rollback_strategy" => "redeploy previous version"
      }
    })
  end

  defmodule IntentActorRequest do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntentActorRequest",
      description: "Request body for approve/reject/cancel operations.",
      type: :object,
      properties: %{
        actor: %Schema{type: :string, description: "Identity of the actor performing the action"},
        reason: %Schema{
          type: :string,
          description: "Optional reason (used for reject and cancel)"
        }
      },
      required: [:actor],
      example: %{
        "actor" => "operator:jane",
        "reason" => "Not safe to proceed at this time"
      }
    })
  end

  # ── Tasks ───────────────────────────────────────────────────────

  defmodule CreateTaskRequest do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "CreateTaskRequest",
      description: "Request body for assigning a task to a sprite.",
      type: :object,
      properties: %{
        repo: %Schema{
          type: :string,
          description: "Target repository in owner/repo format"
        },
        task_kind: %Schema{
          type: :string,
          description: "Kind of task to run (e.g. open_pr_trivial_change)"
        },
        instructions: %Schema{
          type: :string,
          description: "Instructions for the sprite to execute"
        },
        base_branch: %Schema{
          type: :string,
          description: "Branch to base work on (default: main)"
        },
        pr_title: %Schema{
          type: :string,
          description: "Title for the PR to create"
        },
        pr_body: %Schema{
          type: :string,
          description: "Body for the PR to create"
        },
        summary: %Schema{
          type: :string,
          description: "Custom human-readable summary (defaults to auto-generated)"
        }
      },
      required: [:repo, :task_kind, :instructions],
      example: %{
        "repo" => "plattegruber/lattice",
        "task_kind" => "open_pr_trivial_change",
        "instructions" => "Add a build timestamp to README.md",
        "base_branch" => "main",
        "pr_title" => "Add build timestamp",
        "pr_body" => "Automated change via Lattice"
      }
    })
  end

  defmodule TaskIntentData do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "TaskIntentData",
      description: "Task intent data returned after creation.",
      type: :object,
      properties: %{
        intent_id: %Schema{type: :string, description: "Intent identifier"},
        state: %Schema{
          type: :string,
          description: "Current lifecycle state",
          enum: [
            "proposed",
            "classified",
            "awaiting_approval",
            "approved",
            "running",
            "completed",
            "failed",
            "rejected",
            "canceled"
          ]
        },
        classification: %Schema{
          type: :string,
          nullable: true,
          description: "Safety classification",
          enum: ["safe", "controlled", "dangerous"]
        },
        sprite_name: %Schema{type: :string, description: "Target sprite name"},
        repo: %Schema{type: :string, description: "Target repository"}
      },
      required: [:intent_id, :state, :sprite_name, :repo],
      example: %{
        "intent_id" => "int_abc123",
        "state" => "awaiting_approval",
        "classification" => "controlled",
        "sprite_name" => "my-sprite",
        "repo" => "plattegruber/lattice"
      }
    })
  end

  defmodule TaskIntentResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "TaskIntentResponse",
      description: "Response envelope after creating a task intent.",
      type: :object,
      properties: %{
        data: LatticeWeb.Schemas.TaskIntentData,
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end

  # ── Skills ─────────────────────────────────────────────────────────

  defmodule SkillInputSchema do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SkillInput",
      description: "Descriptor for a skill input parameter.",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Parameter name"},
        type: %Schema{
          type: :string,
          description: "Data type",
          enum: ["string", "integer", "boolean", "map"]
        },
        required: %Schema{type: :boolean, description: "Whether the input is required"},
        description: %Schema{
          type: :string,
          nullable: true,
          description: "Human-readable description"
        },
        default: %Schema{description: "Default value when not provided", nullable: true}
      },
      required: [:name, :type, :required],
      example: %{
        "name" => "repo",
        "type" => "string",
        "required" => true,
        "description" => "Target repository in owner/repo format",
        "default" => nil
      }
    })
  end

  defmodule SkillOutputSchema do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SkillOutput",
      description: "Descriptor for a skill output.",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Output name"},
        type: %Schema{type: :string, description: "Data type"},
        description: %Schema{
          type: :string,
          nullable: true,
          description: "Human-readable description"
        }
      },
      required: [:name, :type],
      example: %{
        "name" => "pr_url",
        "type" => "string",
        "description" => "URL of the created pull request"
      }
    })
  end

  defmodule SkillSummary do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SkillSummary",
      description: "Abbreviated skill manifest used in list responses.",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Skill name"},
        description: %Schema{
          type: :string,
          nullable: true,
          description: "Human-readable description"
        },
        input_count: %Schema{type: :integer, description: "Number of input parameters"},
        output_count: %Schema{type: :integer, description: "Number of outputs"},
        permissions: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Required permissions"
        },
        produces_events: %Schema{
          type: :boolean,
          description: "Whether the skill emits protocol events"
        }
      },
      required: [:name, :input_count, :output_count, :permissions, :produces_events],
      example: %{
        "name" => "open_pr",
        "description" => "Opens a pull request on a GitHub repository",
        "input_count" => 3,
        "output_count" => 1,
        "permissions" => ["github:write"],
        "produces_events" => true
      }
    })
  end

  defmodule SkillDetail do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SkillDetail",
      description: "Full skill manifest with inputs, outputs, and permissions.",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Skill name"},
        description: %Schema{
          type: :string,
          nullable: true,
          description: "Human-readable description"
        },
        inputs: %Schema{
          type: :array,
          items: LatticeWeb.Schemas.SkillInputSchema,
          description: "Input parameter descriptors"
        },
        outputs: %Schema{
          type: :array,
          items: LatticeWeb.Schemas.SkillOutputSchema,
          description: "Output descriptors"
        },
        permissions: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Required permissions"
        },
        produces_events: %Schema{
          type: :boolean,
          description: "Whether the skill emits protocol events"
        }
      },
      required: [:name, :inputs, :outputs, :permissions, :produces_events]
    })
  end

  defmodule SkillListResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SkillListResponse",
      description: "List of skill summaries response envelope.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: LatticeWeb.Schemas.SkillSummary,
          description: "Array of skill summaries"
        },
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end

  defmodule SkillDetailResponse do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SkillDetailResponse",
      description: "Single skill detail response envelope.",
      type: :object,
      properties: %{
        data: LatticeWeb.Schemas.SkillDetail,
        timestamp: %Schema{type: :string, format: :datetime, description: "ISO 8601 timestamp"}
      },
      required: [:data, :timestamp]
    })
  end
end
