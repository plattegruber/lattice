defmodule Lattice.DIL.RunnerTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  import Mox

  alias Lattice.DIL.Runner

  setup :verify_on_exit!

  defp with_dil_config(config, fun) do
    previous = Application.get_env(:lattice, :dil, [])
    Application.put_env(:lattice, :dil, config)

    try do
      fun.()
    after
      Application.put_env(:lattice, :dil, previous)
    end
  end

  describe "run/1" do
    test "returns {:ok, :disabled} when DIL is disabled" do
      with_dil_config([enabled: false], fn ->
        assert {:ok, :disabled} = Runner.run()
      end)
    end

    test "returns {:ok, {:skipped, reason}} when a gate fails" do
      # open_dil_issue? returns true — should skip
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts ->
        {:ok, [%{"number" => 1, "title" => "[DIL] Open"}]}
      end)

      with_dil_config([enabled: true, cooldown_hours: 24, rejection_cooldown_hours: 48], fn ->
        assert {:ok, {:skipped, "open DIL issue exists"}} = Runner.run()
      end)
    end

    test "returns {:ok, :gates_passed} when all gates pass" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)
      |> expect(:list_issues, fn _opts ->
        old = DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.to_iso8601()
        {:ok, [%{"created_at" => old}]}
      end)
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      with_dil_config([enabled: true, cooldown_hours: 24, rejection_cooldown_hours: 48], fn ->
        assert {:ok, :gates_passed} = Runner.run()
      end)
    end
  end
end
