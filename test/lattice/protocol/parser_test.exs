defmodule Lattice.Protocol.ParserTest do
  use ExUnit.Case, async: true

  alias Lattice.Protocol.Event
  alias Lattice.Protocol.Parser

  alias Lattice.Protocol.Events.{
    Artifact,
    Assumption,
    Blocked,
    Checkpoint,
    Completion,
    Progress,
    Question,
    Warning
  }

  describe "parse_line/1" do
    test "parses valid artifact event" do
      json =
        Jason.encode!(%{
          "type" => "artifact",
          "kind" => "pull_request",
          "url" => "https://github.com/org/repo/pull/42",
          "metadata" => %{"branch" => "feature-x"}
        })

      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "artifact", data: %Artifact{} = data}} =
               Parser.parse_line(line)

      assert data.kind == "pull_request"
      assert data.url == "https://github.com/org/repo/pull/42"
      assert data.metadata == %{"branch" => "feature-x"}
    end

    test "parses valid question event" do
      json =
        Jason.encode!(%{
          "type" => "question",
          "prompt" => "Which database?",
          "choices" => ["postgres", "mysql"],
          "default" => "postgres"
        })

      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "question", data: %Question{} = data}} =
               Parser.parse_line(line)

      assert data.prompt == "Which database?"
      assert data.choices == ["postgres", "mysql"]
      assert data.default == "postgres"
    end

    test "parses valid assumption event with files" do
      json =
        Jason.encode!(%{
          "type" => "assumption",
          "files" => [
            %{"path" => "lib/app.ex", "lines" => [1, 5], "note" => "module header"},
            %{"path" => "mix.exs", "lines" => [], "note" => nil}
          ]
        })

      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "assumption", data: %Assumption{} = data}} =
               Parser.parse_line(line)

      assert length(data.files) == 2

      [first, second] = data.files
      assert first.path == "lib/app.ex"
      assert first.lines == [1, 5]
      assert first.note == "module header"
      assert second.path == "mix.exs"
      assert second.lines == []
      assert second.note == nil
    end

    test "parses valid blocked event" do
      json = Jason.encode!(%{"type" => "blocked", "reason" => "missing API key"})
      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "blocked", data: %Blocked{} = data}} =
               Parser.parse_line(line)

      assert data.reason == "missing API key"
    end

    test "parses valid progress event with percent" do
      json =
        Jason.encode!(%{
          "type" => "progress",
          "message" => "Compiling",
          "percent" => 75,
          "phase" => "build"
        })

      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "progress", data: %Progress{} = data}} =
               Parser.parse_line(line)

      assert data.message == "Compiling"
      assert data.percent == 75
      assert data.phase == "build"
    end

    test "parses valid progress event without percent" do
      json = Jason.encode!(%{"type" => "progress", "message" => "Starting", "phase" => "init"})
      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "progress", data: %Progress{} = data}} =
               Parser.parse_line(line)

      assert data.message == "Starting"
      assert data.percent == nil
      assert data.phase == "init"
    end

    test "parses valid completion event" do
      json =
        Jason.encode!(%{
          "type" => "completion",
          "status" => "success",
          "summary" => "All tests pass"
        })

      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "completion", data: %Completion{} = data}} =
               Parser.parse_line(line)

      assert data.status == "success"
      assert data.summary == "All tests pass"
    end

    test "parses valid warning event" do
      json =
        Jason.encode!(%{
          "type" => "warning",
          "message" => "Deprecated function used",
          "details" => "String.strip/1 is deprecated"
        })

      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "warning", data: %Warning{} = data}} =
               Parser.parse_line(line)

      assert data.message == "Deprecated function used"
      assert data.details == "String.strip/1 is deprecated"
    end

    test "parses valid checkpoint event" do
      json =
        Jason.encode!(%{
          "type" => "checkpoint",
          "message" => "Tests passing",
          "metadata" => %{"commit" => "abc123"}
        })

      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "checkpoint", data: %Checkpoint{} = data}} =
               Parser.parse_line(line)

      assert data.message == "Tests passing"
      assert data.metadata == %{"commit" => "abc123"}
    end

    test "unknown event type returns event with raw map data" do
      json = Jason.encode!(%{"type" => "custom_thing", "foo" => "bar"})
      line = "LATTICE_EVENT #{json}"

      assert {:event, %Event{type: "custom_thing", data: data}} = Parser.parse_line(line)
      assert is_map(data)
      assert data["foo"] == "bar"
    end

    test "malformed JSON returns {:text, line}" do
      line = "LATTICE_EVENT {not valid json"
      assert {:text, ^line} = Parser.parse_line(line)
    end

    test "missing type field returns {:text, line}" do
      json = Jason.encode!(%{"foo" => "bar"})
      line = "LATTICE_EVENT #{json}"
      assert {:text, ^line} = Parser.parse_line(line)
    end

    test "regular text returns {:text, line}" do
      line = "Hello, this is just normal output"
      assert {:text, ^line} = Parser.parse_line(line)
    end

    test "prefix without space (LATTICE_EVENTfoo) returns {:text, line}" do
      line = "LATTICE_EVENTfoo"
      assert {:text, ^line} = Parser.parse_line(line)
    end
  end
end
