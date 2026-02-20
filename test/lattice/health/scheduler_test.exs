defmodule Lattice.Health.SchedulerTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Events
  alias Lattice.Health.Scheduler
  alias Lattice.Intents.Observation

  # The Scheduler is NOT started by the app in test (enabled: false).
  # We start it per-test with start_supervised!.

  describe "fleet_health check" do
    test "runs fleet health check" do
      Application.put_env(:lattice, Scheduler,
        enabled: true,
        checks: [
          %{type: :fleet_health, name: "test_fleet", interval_ms: 600_000, severity: :critical}
        ]
      )

      pid = start_supervised!(Scheduler)

      send(pid, {:run_check, "test_fleet"})
      Process.sleep(50)

      status = Scheduler.status()
      assert Map.has_key?(status.results, "test_fleet")
      result = status.results["test_fleet"]
      assert result.status in [:ok, :failure]
    after
      Application.delete_env(:lattice, Scheduler)
    end
  end

  describe "http_probe check" do
    test "detects failure on unreachable endpoint" do
      Application.put_env(:lattice, Scheduler,
        enabled: true,
        checks: [
          %{
            type: :http_probe,
            name: "test_http",
            url: "http://localhost:1/nonexistent",
            interval_ms: 600_000,
            timeout_ms: 1_000,
            severity: :high
          }
        ]
      )

      pid = start_supervised!(Scheduler)

      send(pid, {:run_check, "test_http"})
      Process.sleep(200)

      status = Scheduler.status()
      result = status.results["test_http"]
      assert result.status == :failure
    after
      Application.delete_env(:lattice, Scheduler)
    end
  end

  describe "observation emission" do
    test "emits observation when check fails" do
      Events.subscribe_all_observations()

      Application.put_env(:lattice, Scheduler,
        enabled: true,
        checks: [
          %{
            type: :http_probe,
            name: "test_emit",
            url: "http://localhost:1/nonexistent",
            interval_ms: 600_000,
            timeout_ms: 1_000,
            severity: :high
          }
        ]
      )

      pid = start_supervised!(Scheduler)

      send(pid, {:run_check, "test_emit"})

      assert_receive %Observation{type: :anomaly, severity: :high}, 2_000
    after
      Application.delete_env(:lattice, Scheduler)
    end
  end

  describe "status/0" do
    test "returns checks and results" do
      Application.put_env(:lattice, Scheduler,
        enabled: true,
        checks: [
          %{type: :fleet_health, name: "status_test", interval_ms: 600_000}
        ]
      )

      start_supervised!(Scheduler)

      status = Scheduler.status()
      assert is_list(status.checks)
      assert length(status.checks) == 1
      assert is_map(status.results)
    after
      Application.delete_env(:lattice, Scheduler)
    end
  end

  describe "scheduling" do
    test "auto-runs check on schedule" do
      Application.put_env(:lattice, Scheduler,
        enabled: true,
        checks: [
          %{type: :fleet_health, name: "resched_test", interval_ms: 100}
        ]
      )

      start_supervised!(Scheduler)

      # Initial schedule fires after 100ms, wait 250ms for it to complete
      Process.sleep(250)

      status = Scheduler.status()
      assert Map.has_key?(status.results, "resched_test")
    after
      Application.delete_env(:lattice, Scheduler)
    end
  end
end
