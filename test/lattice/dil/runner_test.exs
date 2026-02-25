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

  describe "run/1 — gates" do
    test "returns {:ok, :disabled} when DIL is disabled" do
      with_dil_config([enabled: false], fn ->
        assert {:ok, :disabled} = Runner.run()
      end)
    end

    test "returns {:ok, {:skipped, reason}} when a gate fails" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts ->
        {:ok, [%{"number" => 1, "title" => "[DIL] Open"}]}
      end)

      with_dil_config([enabled: true, cooldown_hours: 24, rejection_cooldown_hours: 48], fn ->
        assert {:ok, {:skipped, "open DIL issue exists"}} = Runner.run()
      end)
    end
  end

  describe "run/1 — pipeline" do
    test "returns candidate or no_candidate when all gates pass" do
      # 3 list_issues calls for gates + 1 for context gathering
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)
      |> expect(:list_issues, fn _opts ->
        old = DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.to_iso8601()
        {:ok, [%{"created_at" => old}]}
      end)
      |> expect(:list_issues, fn _opts -> {:ok, []} end)
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      with_dil_config(
        [enabled: true, cooldown_hours: 24, rejection_cooldown_hours: 48, score_threshold: 18],
        fn ->
          result = Runner.run()
          assert {:ok, {status, _summary}} = result
          assert status in [:candidate, :no_candidate]
        end
      )
    end

    test "skip_gates bypasses all gate checks" do
      # Only 1 list_issues call for context gathering (no gate calls)
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      result = Runner.run(skip_gates: true)
      assert {:ok, {status, _summary}} = result
      assert status in [:candidate, :no_candidate]
    end
  end
end
