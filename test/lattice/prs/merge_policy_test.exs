defmodule Lattice.PRs.MergePolicyTest do
  use ExUnit.Case, async: false

  import Mox

  @moduletag :unit

  alias Lattice.PRs.MergePolicy
  alias Lattice.PRs.PR
  alias Lattice.PRs.Tracker

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Clean open PRs from prior tests
    Tracker.by_state(:open)
    |> Enum.each(fn pr ->
      Tracker.update_pr(pr.repo, pr.number, state: :merged)
    end)

    :ok
  end

  defp make_pr(opts) do
    number = Keyword.fetch!(opts, :number)
    repo = Keyword.get(opts, :repo, "org/repo")

    PR.new(number, repo,
      review_state: Keyword.get(opts, :review_state, :approved),
      mergeable: Keyword.get(opts, :mergeable, true),
      ci_status: Keyword.get(opts, :ci_status, :success),
      state: Keyword.get(opts, :state, :open)
    )
  end

  defp default_policy(overrides \\ %{}) do
    Map.merge(
      %{
        auto_merge: false,
        required_approvals: 1,
        require_ci: true,
        merge_method: :squash
      },
      overrides
    )
  end

  describe "evaluate/2" do
    test "returns merge_ready when all conditions met" do
      pr = make_pr(number: 1, review_state: :approved, mergeable: true, ci_status: :success)
      assert {:merge_ready, ^pr} = MergePolicy.evaluate(pr, default_policy())
    end

    test "returns merge_ready when CI is nil and require_ci is true" do
      pr = make_pr(number: 2, review_state: :approved, mergeable: true, ci_status: nil)
      assert {:merge_ready, _} = MergePolicy.evaluate(pr, default_policy())
    end

    test "returns not_ready when review not approved" do
      pr = make_pr(number: 3, review_state: :pending, mergeable: true, ci_status: :success)
      assert {:not_ready, reasons} = MergePolicy.evaluate(pr, default_policy())
      assert Enum.any?(reasons, &String.contains?(&1, "review not approved"))
    end

    test "returns not_ready when CI failing and require_ci is true" do
      pr = make_pr(number: 4, review_state: :approved, mergeable: true, ci_status: :failure)
      assert {:not_ready, reasons} = MergePolicy.evaluate(pr, default_policy())
      assert Enum.any?(reasons, &String.contains?(&1, "CI not passing"))
    end

    test "returns merge_ready when CI failing but require_ci is false" do
      pr = make_pr(number: 5, review_state: :approved, mergeable: true, ci_status: :failure)
      assert {:merge_ready, _} = MergePolicy.evaluate(pr, default_policy(%{require_ci: false}))
    end

    test "returns conflict when mergeable is false" do
      pr = make_pr(number: 6, review_state: :approved, mergeable: false, ci_status: :success)
      assert {:conflict, ^pr} = MergePolicy.evaluate(pr, default_policy())
    end

    test "returns not_ready when PR is not open" do
      pr = make_pr(number: 7, state: :closed)
      assert {:not_ready, reasons} = MergePolicy.evaluate(pr, default_policy())
      assert Enum.any?(reasons, &String.contains?(&1, "not open"))
    end

    test "returns not_ready when mergeable is nil" do
      pr = make_pr(number: 8, review_state: :approved, mergeable: nil, ci_status: :success)
      assert {:not_ready, reasons} = MergePolicy.evaluate(pr, default_policy())
      assert Enum.any?(reasons, &String.contains?(&1, "mergeable status unknown"))
    end

    test "collects multiple reasons" do
      pr = make_pr(number: 9, review_state: :pending, mergeable: nil, ci_status: :failure)
      assert {:not_ready, reasons} = MergePolicy.evaluate(pr, default_policy())
      assert length(reasons) >= 2
    end
  end

  describe "check_and_evaluate/1" do
    test "fetches PR from GitHub and updates tracker" do
      pr = make_pr(number: 8001, review_state: :approved, mergeable: nil, ci_status: nil)
      {:ok, _} = Tracker.register(pr)

      Lattice.Capabilities.MockGitHub
      |> expect(:get_pull_request, fn 8001 ->
        {:ok, %{"mergeable" => true, "mergeable_state" => "clean"}}
      end)

      assert {:merge_ready, updated} = MergePolicy.check_and_evaluate(pr)
      assert updated.mergeable == true
      assert updated.ci_status == :success
    end

    test "detects conflict from GitHub data" do
      pr = make_pr(number: 8002, review_state: :approved, mergeable: nil)
      {:ok, _} = Tracker.register(pr)

      Lattice.Capabilities.MockGitHub
      |> expect(:get_pull_request, fn 8002 ->
        {:ok, %{"mergeable" => false, "mergeable_state" => "dirty"}}
      end)

      assert {:conflict, _} = MergePolicy.check_and_evaluate(pr)
    end

    test "handles GitHub fetch failure" do
      pr = make_pr(number: 8003)

      Lattice.Capabilities.MockGitHub
      |> expect(:get_pull_request, fn 8003 -> {:error, :not_found} end)

      assert {:error, :not_found} = MergePolicy.check_and_evaluate(pr)
    end
  end

  describe "try_auto_merge/1" do
    test "skips when auto_merge is disabled" do
      pr = make_pr(number: 8010, review_state: :approved, mergeable: true, ci_status: :success)
      assert {:skipped, reason} = MergePolicy.try_auto_merge(pr)
      assert reason =~ "auto_merge is disabled"
    end

    test "merges when auto_merge enabled and conditions met" do
      # Temporarily enable auto_merge
      original = Application.get_env(:lattice, MergePolicy, [])
      Application.put_env(:lattice, MergePolicy, auto_merge: true, merge_method: :squash)

      pr = make_pr(number: 8011, review_state: :approved, mergeable: true, ci_status: :success)
      {:ok, _} = Tracker.register(pr)

      Lattice.Capabilities.MockGitHub
      |> expect(:merge_pull_request, fn 8011, opts ->
        assert opts[:method] == :squash
        {:ok, %{"merged" => true}}
      end)

      assert {:ok, %{"merged" => true}} = MergePolicy.try_auto_merge(pr)

      # Verify tracker was updated
      updated = Tracker.get("org/repo", 8011)
      assert updated.state == :merged

      Application.put_env(:lattice, MergePolicy, original)
    end

    test "skips when conditions not met" do
      original = Application.get_env(:lattice, MergePolicy, [])
      Application.put_env(:lattice, MergePolicy, auto_merge: true)

      pr = make_pr(number: 8012, review_state: :pending, mergeable: true, ci_status: :success)
      assert {:skipped, reason} = MergePolicy.try_auto_merge(pr)
      assert reason =~ "conditions not met"

      Application.put_env(:lattice, MergePolicy, original)
    end

    test "skips when PR has conflicts" do
      original = Application.get_env(:lattice, MergePolicy, [])
      Application.put_env(:lattice, MergePolicy, auto_merge: true)

      pr = make_pr(number: 8013, review_state: :approved, mergeable: false, ci_status: :success)
      assert {:skipped, reason} = MergePolicy.try_auto_merge(pr)
      assert reason =~ "merge conflicts"

      Application.put_env(:lattice, MergePolicy, original)
    end
  end

  describe "policy/0" do
    test "returns default policy when no config" do
      p = MergePolicy.policy()
      assert p.auto_merge == false
      assert p.required_approvals == 1
      assert p.require_ci == true
      assert p.merge_method == :squash
    end
  end
end
