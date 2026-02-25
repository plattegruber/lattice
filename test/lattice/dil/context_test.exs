defmodule Lattice.DIL.ContextTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  import Mox

  alias Lattice.DIL.Context

  setup :verify_on_exit!

  describe "gather/0" do
    test "returns a Context struct with signals from the repo" do
      # Mock GitHub for recent issues
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn opts ->
        assert opts[:state] == "closed"
        {:ok, [%{"number" => 1, "title" => "Fix something"}]}
      end)

      ctx = Context.gather()

      assert %Context{} = ctx
      assert is_list(ctx.todos)
      assert is_list(ctx.missing_moduledocs)
      assert is_list(ctx.missing_typespecs)
      assert is_list(ctx.large_files)
      assert is_list(ctx.test_gaps)
      assert [%{"number" => 1}] = ctx.recent_issues
    end

    test "handles GitHub errors gracefully" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:error, :api_error} end)

      ctx = Context.gather()

      assert ctx.recent_issues == []
    end

    test "detects TODOs in lib/ files" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      ctx = Context.gather()

      # Our codebase may or may not have TODOs — just verify the structure
      Enum.each(ctx.todos, fn todo ->
        assert Map.has_key?(todo, :file)
        assert Map.has_key?(todo, :line)
        assert Map.has_key?(todo, :detail)
      end)
    end

    test "signals have expected shape" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      ctx = Context.gather()

      for signal_list <- [
            ctx.missing_moduledocs,
            ctx.missing_typespecs,
            ctx.large_files,
            ctx.test_gaps
          ] do
        Enum.each(signal_list, fn signal ->
          assert Map.has_key?(signal, :file)
          assert Map.has_key?(signal, :detail)
        end)
      end
    end
  end
end
