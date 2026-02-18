defmodule Lattice.Protocol.OutboxTest do
  use ExUnit.Case, async: true

  import Mox

  alias Lattice.Protocol.Event
  alias Lattice.Protocol.Outbox

  setup :verify_on_exit!

  # ── parse/1 ──────────────────────────────────────────────────────────

  describe "parse/1" do
    test "parses multi-line JSONL into events" do
      jsonl =
        [
          Jason.encode!(%{"type" => "progress", "message" => "Starting", "phase" => "init"}),
          Jason.encode!(%{
            "type" => "artifact",
            "kind" => "pull_request",
            "url" => "https://github.com/org/repo/pull/1"
          }),
          Jason.encode!(%{"type" => "completion", "status" => "success", "summary" => "Done"})
        ]
        |> Enum.join("\n")

      events = Outbox.parse(jsonl)

      assert length(events) == 3
      assert Enum.map(events, & &1.type) == ["progress", "artifact", "completion"]
    end

    test "skips malformed lines and parses valid ones" do
      jsonl =
        [
          Jason.encode!(%{"type" => "progress", "message" => "OK", "phase" => "build"}),
          "this is not valid json {{{",
          Jason.encode!(%{"type" => "checkpoint", "message" => "Tests pass"})
        ]
        |> Enum.join("\n")

      events = Outbox.parse(jsonl)

      assert length(events) == 2
      assert Enum.map(events, & &1.type) == ["progress", "checkpoint"]
    end

    test "skips lines missing type field" do
      jsonl =
        [
          Jason.encode!(%{"foo" => "bar"}),
          Jason.encode!(%{"type" => "progress", "message" => "OK", "phase" => "init"})
        ]
        |> Enum.join("\n")

      events = Outbox.parse(jsonl)

      assert length(events) == 1
      assert hd(events).type == "progress"
    end

    test "returns empty list for nil input" do
      assert Outbox.parse(nil) == []
    end

    test "returns empty list for empty string" do
      assert Outbox.parse("") == []
    end

    test "handles trailing newline" do
      jsonl = Jason.encode!(%{"type" => "progress", "message" => "OK", "phase" => "init"}) <> "\n"
      events = Outbox.parse(jsonl)

      assert length(events) == 1
      assert hd(events).type == "progress"
    end

    test "handles blank lines between events" do
      jsonl =
        [
          Jason.encode!(%{"type" => "progress", "message" => "A", "phase" => "init"}),
          "",
          "  ",
          Jason.encode!(%{"type" => "completion", "status" => "success", "summary" => "B"})
        ]
        |> Enum.join("\n")

      events = Outbox.parse(jsonl)

      assert length(events) == 2
    end

    test "preserves event data from typed events" do
      jsonl =
        Jason.encode!(%{
          "type" => "artifact",
          "kind" => "pull_request",
          "url" => "https://github.com/org/repo/pull/42",
          "metadata" => %{"branch" => "feature-x"}
        })

      [event] = Outbox.parse(jsonl)

      assert event.type == "artifact"
      assert event.data.kind == "pull_request"
      assert event.data.url == "https://github.com/org/repo/pull/42"
    end
  end

  # ── reconcile/2 ─────────────────────────────────────────────────────

  describe "reconcile/2" do
    test "returns streamed events when outbox is empty" do
      ts = ~U[2026-02-17 10:00:00Z]
      streamed = [Event.new("progress", %{message: "hi"}, timestamp: ts)]

      result = Outbox.reconcile(streamed, [])

      assert length(result) == 1
      assert hd(result).type == "progress"
    end

    test "returns outbox events when streamed is empty" do
      ts = ~U[2026-02-17 10:00:00Z]
      outbox = [Event.new("artifact", %{kind: "pr"}, timestamp: ts)]

      result = Outbox.reconcile([], outbox)

      assert length(result) == 1
      assert hd(result).type == "artifact"
    end

    test "deduplicates by type + timestamp, preferring outbox version" do
      ts = ~U[2026-02-17 10:00:00Z]

      streamed_event = Event.new("progress", %{message: "streamed"}, timestamp: ts)
      outbox_event = Event.new("progress", %{message: "outbox-complete"}, timestamp: ts)

      result = Outbox.reconcile([streamed_event], [outbox_event])

      assert length(result) == 1
      assert hd(result).data == %{message: "outbox-complete"}
    end

    test "includes events unique to streamed list" do
      ts1 = ~U[2026-02-17 10:00:00Z]
      ts2 = ~U[2026-02-17 10:01:00Z]

      streamed = [
        Event.new("progress", %{message: "a"}, timestamp: ts1),
        Event.new("checkpoint", %{message: "b"}, timestamp: ts2)
      ]

      outbox = [
        Event.new("progress", %{message: "a-outbox"}, timestamp: ts1)
      ]

      result = Outbox.reconcile(streamed, outbox)

      assert length(result) == 2
      types = Enum.map(result, & &1.type)
      assert "progress" in types
      assert "checkpoint" in types
    end

    test "includes events unique to outbox list" do
      ts1 = ~U[2026-02-17 10:00:00Z]
      ts2 = ~U[2026-02-17 10:02:00Z]

      streamed = [
        Event.new("progress", %{message: "a"}, timestamp: ts1)
      ]

      outbox = [
        Event.new("progress", %{message: "a-outbox"}, timestamp: ts1),
        Event.new("artifact", %{kind: "pr"}, timestamp: ts2)
      ]

      result = Outbox.reconcile(streamed, outbox)

      assert length(result) == 2

      # Verify outbox-only event is included
      artifact = Enum.find(result, &(&1.type == "artifact"))
      assert artifact != nil
      assert artifact.data == %{kind: "pr"}
    end

    test "result is sorted by timestamp ascending" do
      ts1 = ~U[2026-02-17 10:00:00Z]
      ts2 = ~U[2026-02-17 10:01:00Z]
      ts3 = ~U[2026-02-17 10:02:00Z]

      streamed = [
        Event.new("progress", %{message: "first"}, timestamp: ts1),
        Event.new("checkpoint", %{message: "third"}, timestamp: ts3)
      ]

      outbox = [
        Event.new("artifact", %{kind: "pr"}, timestamp: ts2)
      ]

      result = Outbox.reconcile(streamed, outbox)

      assert length(result) == 3
      timestamps = Enum.map(result, & &1.timestamp)
      assert timestamps == [ts1, ts2, ts3]
    end

    test "handles both lists empty" do
      assert Outbox.reconcile([], []) == []
    end

    test "multiple events with same type but different timestamps are not deduped" do
      ts1 = ~U[2026-02-17 10:00:00Z]
      ts2 = ~U[2026-02-17 10:01:00Z]

      streamed = [
        Event.new("progress", %{message: "a"}, timestamp: ts1),
        Event.new("progress", %{message: "b"}, timestamp: ts2)
      ]

      result = Outbox.reconcile(streamed, [])

      assert length(result) == 2
    end
  end

  # ── fetch/2 ─────────────────────────────────────────────────────────

  describe "fetch/2" do
    test "returns content when outbox file exists" do
      outbox_content = ~s|{"type":"progress","message":"OK","phase":"init"}|

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn sprite_name, command ->
        assert sprite_name == "test-sprite"
        assert command =~ "cat /workspace/.lattice/outbox.jsonl"
        {:ok, %{output: outbox_content <> "\n0", exit_code: 0}}
      end)

      assert {:ok, ^outbox_content} = Outbox.fetch("test-sprite", "session-123")
    end

    test "returns nil when outbox file does not exist" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _sprite_name, _command ->
        # cat fails with exit code 1 (file not found), suppressed by 2>/dev/null
        # echo $? outputs "1"
        {:ok, %{output: "\n1", exit_code: 0}}
      end)

      assert {:ok, nil} = Outbox.fetch("test-sprite", "session-123")
    end

    test "returns error when sprite is unreachable" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _sprite_name, _command ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Outbox.fetch("test-sprite", "session-123")
    end

    test "returns nil when exec returns non-zero exit code" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _sprite_name, _command ->
        {:ok, %{output: "error output", exit_code: 1}}
      end)

      assert {:ok, nil} = Outbox.fetch("test-sprite", "session-123")
    end

    test "returns nil for empty outbox file" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _sprite_name, _command ->
        {:ok, %{output: "\n0", exit_code: 0}}
      end)

      assert {:ok, nil} = Outbox.fetch("test-sprite", "session-123")
    end

    test "handles multi-line outbox content" do
      lines = [
        ~s|{"type":"progress","message":"A","phase":"init"}|,
        ~s|{"type":"completion","status":"success","summary":"B"}|
      ]

      content = Enum.join(lines, "\n")

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _sprite_name, _command ->
        {:ok, %{output: content <> "\n0", exit_code: 0}}
      end)

      assert {:ok, result} = Outbox.fetch("test-sprite", "session-123")
      assert result == content
    end
  end
end
