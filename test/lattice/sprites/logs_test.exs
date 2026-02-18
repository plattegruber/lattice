defmodule Lattice.Sprites.LogsTest do
  use ExUnit.Case, async: true

  alias Lattice.Sprites.Logs

  @moduletag :unit

  describe "strip_ansi/1" do
    test "strips color codes" do
      assert Logs.strip_ansi("\e[31mError\e[0m") == "Error"
    end

    test "strips bold and other styles" do
      assert Logs.strip_ansi("\e[1;32mSuccess\e[0m") == "Success"
    end

    test "strips OSC sequences" do
      assert Logs.strip_ansi("\e]0;window title\atesting") == "testing"
    end

    test "strips CSI sequences with ? prefix" do
      assert Logs.strip_ansi("\e[?25hvisible") == "visible"
    end

    test "returns plain text unchanged" do
      assert Logs.strip_ansi("no codes here") == "no codes here"
    end

    test "handles empty string" do
      assert Logs.strip_ansi("") == ""
    end

    test "handles non-string input" do
      assert Logs.strip_ansi(123) == "123"
    end
  end

  describe "from_event/3" do
    test "creates log line from state_change event" do
      line =
        Logs.from_event(:state_change, "sprite-1", %{
          from: :hibernating,
          to: :waking,
          reason: "operator request"
        })

      assert line.source == :state_change
      assert line.sprite_id == "sprite-1"
      assert line.level == :info
      assert line.message =~ "hibernating -> waking"
      assert line.message =~ "operator request"
      assert %DateTime{} = line.timestamp
      assert is_integer(line.id)
    end

    test "creates log line from state_change without reason" do
      line =
        Logs.from_event(:state_change, "sprite-1", %{
          from: :hibernating,
          to: :waking
        })

      assert line.message == "State changed: hibernating -> waking"
    end

    test "creates log line from reconciliation failure" do
      line =
        Logs.from_event(:reconciliation, "sprite-1", %{
          outcome: :failure,
          details: "API timeout"
        })

      assert line.level == :error
      assert line.message =~ "failure"
      assert line.message =~ "API timeout"
    end

    test "creates log line from reconciliation success" do
      line =
        Logs.from_event(:reconciliation, "sprite-1", %{
          outcome: :success
        })

      assert line.level == :info
      assert line.message =~ "success"
    end

    test "creates log line from health update" do
      line =
        Logs.from_event(:health, "sprite-1", %{
          status: :degraded,
          message: "high latency"
        })

      assert line.level == :warn
      assert line.message =~ "degraded"
    end

    test "creates log line from unhealthy health update" do
      line =
        Logs.from_event(:health, "sprite-1", %{
          status: :unhealthy,
          message: "not responding"
        })

      assert line.level == :error
    end

    test "creates log line from unknown event type" do
      line = Logs.from_event(:unknown, "sprite-1", %{foo: "bar"})

      assert line.level == :info
      assert line.message =~ "unknown"
    end
  end

  describe "from_exec_output/1" do
    test "creates log line from stdout" do
      line =
        Logs.from_exec_output(%{
          session_id: "exec_123",
          stream: :stdout,
          chunk: "Hello world"
        })

      assert line.source == :exec
      assert line.level == :info
      assert line.message == "Hello world"
    end

    test "creates log line from stderr with error level" do
      line =
        Logs.from_exec_output(%{
          session_id: "exec_123",
          stream: :stderr,
          chunk: "something went wrong"
        })

      assert line.level == :error
    end

    test "strips ANSI codes from exec output" do
      line =
        Logs.from_exec_output(%{
          session_id: "exec_123",
          stream: :stdout,
          chunk: "\e[32mgreen text\e[0m"
        })

      assert line.message == "green text"
    end
  end
end
