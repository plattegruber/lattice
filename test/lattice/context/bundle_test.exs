defmodule Lattice.Context.BundleTest do
  use ExUnit.Case
  @moduletag :unit

  alias Lattice.Context.Bundle
  alias Lattice.Context.Trigger

  @trigger %Trigger{
    type: :issue,
    number: 42,
    repo: "owner/repo",
    title: "Test issue",
    body: "Some body"
  }

  describe "new/2" do
    test "creates a bundle from a trigger" do
      bundle = Bundle.new(@trigger)

      assert bundle.trigger_type == :issue
      assert bundle.trigger_number == 42
      assert bundle.repo == "owner/repo"
      assert bundle.title == "Test issue"
      assert bundle.files == []
      assert bundle.linked_items == []
      assert bundle.expansion_budget == %{used: 0, max: 5}
      assert bundle.warnings == []
      assert %DateTime{} = bundle.gathered_at
    end

    test "accepts custom max_expansions" do
      bundle = Bundle.new(@trigger, max_expansions: 10)
      assert bundle.expansion_budget == %{used: 0, max: 10}
    end
  end

  describe "add_file/4" do
    test "appends a file entry" do
      bundle =
        Bundle.new(@trigger)
        |> Bundle.add_file("trigger.md", "# Hello", "trigger")

      assert length(bundle.files) == 1
      [file] = bundle.files
      assert file.path == "trigger.md"
      assert file.content == "# Hello"
      assert file.kind == "trigger"
    end

    test "preserves order of multiple files" do
      bundle =
        Bundle.new(@trigger)
        |> Bundle.add_file("a.md", "A", "first")
        |> Bundle.add_file("b.md", "B", "second")

      assert [%{path: "a.md"}, %{path: "b.md"}] = bundle.files
    end
  end

  describe "add_linked_item/4" do
    test "adds item and increments budget" do
      bundle =
        Bundle.new(@trigger)
        |> Bundle.add_linked_item("issue", 10, "Some issue")

      assert length(bundle.linked_items) == 1
      assert hd(bundle.linked_items).number == 10
      assert bundle.expansion_budget.used == 1
    end
  end

  describe "add_warning/2" do
    test "appends a warning" do
      bundle =
        Bundle.new(@trigger)
        |> Bundle.add_warning("something went wrong")

      assert bundle.warnings == ["something went wrong"]
    end
  end

  describe "budget_remaining?/1" do
    test "returns true when budget has capacity" do
      bundle = Bundle.new(@trigger, max_expansions: 3)
      assert Bundle.budget_remaining?(bundle)
    end

    test "returns false when budget is exhausted" do
      bundle =
        Bundle.new(@trigger, max_expansions: 1)
        |> Bundle.add_linked_item("issue", 1, "x")

      refute Bundle.budget_remaining?(bundle)
    end
  end

  describe "total_size/1" do
    test "sums byte sizes of all file contents" do
      bundle =
        Bundle.new(@trigger)
        |> Bundle.add_file("a.md", "hello", "trigger")
        |> Bundle.add_file("b.md", "world!", "thread")

      assert Bundle.total_size(bundle) == byte_size("hello") + byte_size("world!")
    end

    test "returns 0 for empty bundle" do
      assert Bundle.total_size(Bundle.new(@trigger)) == 0
    end
  end

  describe "to_manifest/1" do
    test "returns a JSON-encodable map" do
      bundle =
        Bundle.new(@trigger)
        |> Bundle.add_file("trigger.md", "content", "trigger")
        |> Bundle.add_linked_item("issue", 10, "Linked")
        |> Bundle.add_warning("warn")

      manifest = Bundle.to_manifest(bundle)

      assert manifest.version == "v1"
      assert manifest.trigger_type == "issue"
      assert manifest.trigger_number == 42
      assert manifest.repo == "owner/repo"
      assert is_binary(manifest.gathered_at)
      assert [%{path: "trigger.md", kind: "trigger"}] = manifest.files
      assert [%{type: "issue", number: 10, title: "Linked"}] = manifest.linked_items
      assert manifest.expansion_budget == %{used: 1, max: 5}
      assert manifest.warnings == ["warn"]
    end
  end

  describe "to_manifest_json/1" do
    test "returns valid JSON string" do
      bundle = Bundle.new(@trigger)
      json = Bundle.to_manifest_json(bundle)

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["version"] == "v1"
      assert decoded["trigger_number"] == 42
    end
  end
end
