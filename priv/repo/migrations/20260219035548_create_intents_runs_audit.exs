defmodule Lattice.Repo.Migrations.CreateIntentsRunsAudit do
  use Ecto.Migration

  def change do
    # ── Intents ──────────────────────────────────────────────────────

    create table(:intents, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :state, :string, null: false
      add :classification, :string
      add :source_type, :string, null: false
      add :source_id, :string, null: false
      add :summary, :text, null: false
      add :payload, :map, default: %{}
      add :metadata, :map, default: %{}
      add :result, :map
      add :affected_resources, {:array, :string}, default: []
      add :expected_side_effects, {:array, :string}, default: []
      add :rollback_strategy, :text
      add :rollback_for, :string
      add :plan, :map
      add :transition_log, {:array, :map}, default: []
      add :blocked_reason, :text
      add :pending_question, :map

      add :classified_at, :utc_datetime_usec
      add :approved_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :blocked_at, :utc_datetime_usec
      add :resumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:intents, [:state])
    create index(:intents, [:kind])
    create index(:intents, [:source_type])
    create index(:intents, [:classification])
    create index(:intents, [:rollback_for])
    create index(:intents, [:inserted_at])

    # ── Runs ─────────────────────────────────────────────────────────

    create table(:runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :intent_id, references(:intents, type: :string, on_delete: :nilify_all)
      add :sprite_name, :string, null: false
      add :command, :text
      add :mode, :string
      add :status, :string, null: false
      add :exit_code, :integer
      add :error, :text
      add :blocked_reason, :text
      add :question, :map
      add :answer, :map
      add :artifacts, {:array, :map}, default: []
      add :assumptions, {:array, :map}, default: []

      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:intent_id])
    create index(:runs, [:status])
    create index(:runs, [:sprite_name])
    create index(:runs, [:inserted_at])

    # ── Audit Entries ────────────────────────────────────────────────

    create table(:audit_entries) do
      add :intent_id, :string
      add :action, :string, null: false
      add :actor, :string
      add :details, :map, default: %{}

      add :timestamp, :utc_datetime_usec, null: false
    end

    create index(:audit_entries, [:intent_id])
    create index(:audit_entries, [:action])
    create index(:audit_entries, [:timestamp])
  end
end
