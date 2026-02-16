defmodule Lattice.Safety.AuditTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Safety.Audit
  alias Lattice.Safety.AuditEntry

  # ── Telemetry Emission ─────────────────────────────────────────────

  describe "log/6 telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "audit-test-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:lattice, :safety, :audit],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "emits a telemetry event for a successful action", %{ref: ref} do
      Audit.log(:sprites, :wake, :controlled, :ok, :human, args: ["sprite-001"])

      assert_receive {:telemetry, ^ref, [:lattice, :safety, :audit], measurements, metadata}

      assert %{system_time: _} = measurements
      assert %AuditEntry{} = metadata.entry
      assert metadata.entry.capability == :sprites
      assert metadata.entry.operation == :wake
      assert metadata.entry.classification == :controlled
      assert metadata.entry.result == :ok
      assert metadata.entry.actor == :human
      assert metadata.entry.args == ["sprite-001"]
    end

    test "emits a telemetry event for a denied action", %{ref: ref} do
      Audit.log(:fly, :deploy, :dangerous, :denied, :system)

      assert_receive {:telemetry, ^ref, [:lattice, :safety, :audit], _measurements, metadata}

      assert metadata.entry.result == :denied
      assert metadata.entry.classification == :dangerous
    end

    test "emits a telemetry event for a failed action", %{ref: ref} do
      Audit.log(:sprites, :exec, :controlled, {:error, :timeout}, :scheduled)

      assert_receive {:telemetry, ^ref, [:lattice, :safety, :audit], _measurements, metadata}

      assert metadata.entry.result == {:error, :timeout}
      assert metadata.entry.actor == :scheduled
    end
  end

  # ── PubSub Broadcast ───────────────────────────────────────────────

  describe "log/6 PubSub" do
    test "broadcasts audit entry on safety:audit topic" do
      Phoenix.PubSub.subscribe(Lattice.PubSub, "safety:audit")

      Audit.log(:sprites, :list_sprites, :safe, :ok, :system)

      assert_receive %AuditEntry{
        capability: :sprites,
        operation: :list_sprites,
        classification: :safe,
        result: :ok,
        actor: :system
      }
    end
  end

  # ── Argument Sanitization ──────────────────────────────────────────

  describe "sanitize_args/1" do
    test "redacts atom keys matching sensitive patterns" do
      args = [%{token: "abc123", name: "atlas"}]
      assert [%{token: "[REDACTED]", name: "atlas"}] = Audit.sanitize_args(args)
    end

    test "redacts multiple sensitive keys" do
      args = [%{password: "secret", api_key: "key123", user: "admin"}]
      [sanitized] = Audit.sanitize_args(args)

      assert sanitized.password == "[REDACTED]"
      assert sanitized.api_key == "[REDACTED]"
      assert sanitized.user == "admin"
    end

    test "passes through non-map arguments unchanged" do
      assert Audit.sanitize_args(["sprite-001", 42, :atom]) == ["sprite-001", 42, :atom]
    end

    test "handles empty args" do
      assert Audit.sanitize_args([]) == []
    end

    test "handles mixed argument types" do
      args = ["sprite-001", %{token: "secret", command: "echo hello"}]
      [first, second] = Audit.sanitize_args(args)

      assert first == "sprite-001"
      assert second.token == "[REDACTED]"
      assert second.command == "echo hello"
    end
  end

  # ── Sanitization in log/6 ──────────────────────────────────────────

  describe "log/6 sanitization" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "audit-sanitize-test-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:lattice, :safety, :audit],
        fn _event_name, _measurements, metadata, _config ->
          send(test_pid, {:audit_entry, ref, metadata.entry})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "sanitizes args before emitting", %{ref: ref} do
      Audit.log(:sprites, :exec, :controlled, :ok, :human,
        args: ["sprite-001", %{token: "secret-token", command: "ls"}]
      )

      assert_receive {:audit_entry, ^ref, entry}

      [sprite_id, config] = entry.args
      assert sprite_id == "sprite-001"
      assert config.token == "[REDACTED]"
      assert config.command == "ls"
    end
  end
end
