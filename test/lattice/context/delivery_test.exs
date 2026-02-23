defmodule Lattice.Context.DeliveryTest do
  use ExUnit.Case
  @moduletag :unit

  import Mox

  alias Lattice.Context.Bundle
  alias Lattice.Context.Delivery
  alias Lattice.Context.Trigger

  setup :set_mox_global
  setup :verify_on_exit!

  @trigger %Trigger{
    type: :issue,
    number: 42,
    repo: "owner/repo",
    title: "Test issue"
  }

  defp build_bundle do
    Bundle.new(@trigger)
    |> Bundle.add_file("trigger.md", "# Issue #42", "trigger")
    |> Bundle.add_file("thread.md", "_No comments._", "thread")
  end

  defp build_bundle_with_linked do
    build_bundle()
    |> Bundle.add_file("linked/issue_10.md", "# Issue #10", "linked_issue")
  end

  describe "deliver/2" do
    test "clears dir, creates subdirs, writes manifest and files, verifies" do
      bundle = build_bundle()

      Lattice.Capabilities.MockSprites
      # 1. rm -rf && mkdir -p (clear)
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ "rm -rf"
        assert cmd =~ "/workspace/.lattice/context"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 2. No mkdir for subdirs needed (no linked/ files)
      # 3. FileWriter: manifest.json write first chunk
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ ".b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 4. FileWriter: manifest.json decode
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ "base64 -d"
        assert cmd =~ "manifest.json"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 5. FileWriter: trigger.md write first chunk
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ ".b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 6. FileWriter: trigger.md decode
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ "base64 -d"
        assert cmd =~ "trigger.md"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 7. FileWriter: thread.md write first chunk
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ ".b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 8. FileWriter: thread.md decode
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ "base64 -d"
        assert cmd =~ "thread.md"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 9. Verify: ls -la
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ "ls -la"
        {:ok, %{output: "manifest.json trigger.md thread.md", exit_code: 0}}
      end)

      assert :ok = Delivery.deliver("sprite-1", bundle)
    end

    test "creates subdirs when linked files are present" do
      bundle = build_bundle_with_linked()

      Lattice.Capabilities.MockSprites
      # 1. clear
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ "rm -rf"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 2. mkdir -p for linked/
      |> expect(:exec, fn "sprite-1", cmd ->
        assert cmd =~ "mkdir -p"
        assert cmd =~ "linked"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 3-12: manifest + 3 files = 4 * 2 (write + decode) = 8 exec calls
      |> expect(:exec, 8, fn "sprite-1", _cmd ->
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 13. verify
      |> expect(:exec, fn "sprite-1", _cmd ->
        {:ok, %{output: "ok", exit_code: 0}}
      end)

      assert :ok = Delivery.deliver("sprite-1", bundle)
    end

    test "returns error when clear fails" do
      bundle = build_bundle()

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "sprite-1", _cmd ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} = Delivery.deliver("sprite-1", bundle)
    end

    test "returns error when file write fails" do
      bundle = build_bundle()

      Lattice.Capabilities.MockSprites
      # clear succeeds
      |> expect(:exec, fn "sprite-1", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      # manifest write fails (non-retryable)
      |> expect(:exec, fn "sprite-1", _cmd -> {:error, :write_failed} end)

      assert {:error, :write_failed} = Delivery.deliver("sprite-1", bundle)
    end
  end
end
