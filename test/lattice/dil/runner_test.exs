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

  describe "run/1 — live mode" do
    test "creates GitHub issue in live mode" do
      # 1 list_issues for context gathering + 1 create_issue
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)
      |> expect(:create_issue, fn title, attrs ->
        assert title =~ "[DIL]"
        assert is_binary(attrs.body)
        assert "dil-proposal" in attrs.labels
        assert "research-backed" in attrs.labels
        {:ok, %{"number" => 42, "title" => title}}
      end)

      with_dil_config([enabled: true, mode: :live, score_threshold: 0], fn ->
        result = Runner.run(skip_gates: true)

        case result do
          {:ok, {:candidate, summary}} ->
            assert summary.mode == :live
            assert summary.issue_number == 42

          {:ok, {:no_candidate, _}} ->
            # Acceptable if no candidates found in the repo
            :ok
        end
      end)
    end

    test "dry-run mode does NOT call create_issue" do
      # Only list_issues for context — no create_issue expected
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      with_dil_config([enabled: true, mode: :dry_run, score_threshold: 0], fn ->
        result = Runner.run(skip_gates: true)
        assert {:ok, {status, _}} = result
        assert status in [:candidate, :no_candidate]
      end)
    end
  end
end
