defmodule Lattice.Safety.AuditOperatorTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Auth.Operator
  alias Lattice.Safety.Audit
  alias Lattice.Safety.AuditEntry

  describe "log/6 with operator" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "audit-operator-test-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:lattice, :safety, :audit],
        fn _event_name, _measurements, metadata, _config ->
          send(test_pid, {:audit_entry, ref, metadata.entry})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, operator} = Operator.new("user_123", "Ada Lovelace", :operator)
      %{ref: ref, operator: operator}
    end

    test "includes operator in audit entry", %{ref: ref, operator: operator} do
      Audit.log(:sprites, :wake, :controlled, :ok, :human, operator: operator)

      assert_receive {:audit_entry, ^ref, entry}

      assert %AuditEntry{} = entry
      assert entry.operator == operator
      assert entry.operator.id == "user_123"
      assert entry.operator.name == "Ada Lovelace"
      assert entry.operator.role == :operator
    end

    test "operator defaults to nil when not provided", %{ref: ref} do
      Audit.log(:sprites, :list_sprites, :safe, :ok, :system)

      assert_receive {:audit_entry, ^ref, entry}

      assert entry.operator == nil
    end
  end

  describe "AuditEntry.new/6 with operator" do
    test "accepts operator in opts" do
      {:ok, operator} = Operator.new("op-1", "Test", :admin)

      {:ok, entry} =
        AuditEntry.new(:sprites, :wake, :controlled, :ok, :human, operator: operator)

      assert entry.operator == operator
    end

    test "operator defaults to nil" do
      {:ok, entry} = AuditEntry.new(:sprites, :wake, :controlled, :ok, :human)
      assert entry.operator == nil
    end
  end
end
