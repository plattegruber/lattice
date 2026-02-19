defmodule Lattice.PRs.MonitorTest do
  use ExUnit.Case, async: false

  import Mox

  @moduletag :unit

  alias Lattice.PRs.Monitor
  alias Lattice.PRs.PR
  alias Lattice.PRs.Tracker

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Close all open PRs from prior tests to avoid leaking state
    Tracker.by_state(:open)
    |> Enum.each(fn pr ->
      Tracker.update_pr(pr.repo, pr.number, state: :merged)
    end)

    :ok
  end

  defp register_pr(opts) do
    number = Keyword.fetch!(opts, :number)
    repo = Keyword.get(opts, :repo, "org/repo")

    pr =
      PR.new(number, repo,
        review_state: Keyword.get(opts, :review_state, :pending),
        intent_id: Keyword.get(opts, :intent_id),
        url: Keyword.get(opts, :url, "https://github.com/#{repo}/pull/#{number}"),
        title: Keyword.get(opts, :title, "Test PR")
      )

    {:ok, _} = Tracker.register(pr)
    pr
  end

  describe "poll cycle" do
    test "detects review state change from pending to changes_requested" do
      pr = register_pr(number: 9001, review_state: :pending)

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 9001 ->
        {:ok,
         [
           %{
             "user" => %{"login" => "reviewer1"},
             "state" => "CHANGES_REQUESTED",
             "submitted_at" => "2026-02-18T10:00:00Z"
           }
         ]}
      end)

      {:ok, monitor} =
        Monitor.start_link(
          name: :test_monitor_1,
          interval_ms: :timer.hours(1),
          auto_fixup: false
        )

      Monitor.poll_now(monitor)
      Process.sleep(50)

      updated = Tracker.get(pr.repo, pr.number)
      assert updated.review_state == :changes_requested

      GenServer.stop(monitor)
    end

    test "does not update when review state is unchanged" do
      register_pr(number: 9002, review_state: :approved)

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 9002 ->
        {:ok,
         [
           %{
             "user" => %{"login" => "reviewer1"},
             "state" => "APPROVED",
             "submitted_at" => "2026-02-18T10:00:00Z"
           }
         ]}
      end)

      {:ok, monitor} =
        Monitor.start_link(
          name: :test_monitor_2,
          interval_ms: :timer.hours(1),
          auto_fixup: false
        )

      Monitor.poll_now(monitor)
      Process.sleep(50)

      updated = Tracker.get("org/repo", 9002)
      assert updated.review_state == :approved

      GenServer.stop(monitor)
    end

    test "handles review fetch failure gracefully" do
      register_pr(number: 9003, review_state: :pending)

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 9003 -> {:error, :unauthorized} end)

      {:ok, monitor} =
        Monitor.start_link(
          name: :test_monitor_3,
          interval_ms: :timer.hours(1),
          auto_fixup: false
        )

      Monitor.poll_now(monitor)
      Process.sleep(50)

      updated = Tracker.get("org/repo", 9003)
      assert updated.review_state == :pending

      GenServer.stop(monitor)
    end

    test "derives pending state from empty reviews" do
      register_pr(number: 9004, review_state: :pending)

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 9004 -> {:ok, []} end)

      {:ok, monitor} =
        Monitor.start_link(
          name: :test_monitor_4,
          interval_ms: :timer.hours(1),
          auto_fixup: false
        )

      Monitor.poll_now(monitor)
      Process.sleep(50)

      updated = Tracker.get("org/repo", 9004)
      assert updated.review_state == :pending

      GenServer.stop(monitor)
    end

    test "takes latest review per reviewer" do
      register_pr(number: 9005, review_state: :pending)

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 9005 ->
        {:ok,
         [
           %{
             "user" => %{"login" => "reviewer1"},
             "state" => "CHANGES_REQUESTED",
             "submitted_at" => "2026-02-18T08:00:00Z"
           },
           %{
             "user" => %{"login" => "reviewer1"},
             "state" => "APPROVED",
             "submitted_at" => "2026-02-18T10:00:00Z"
           }
         ]}
      end)

      {:ok, monitor} =
        Monitor.start_link(
          name: :test_monitor_5,
          interval_ms: :timer.hours(1),
          auto_fixup: false
        )

      Monitor.poll_now(monitor)
      Process.sleep(50)

      updated = Tracker.get("org/repo", 9005)
      assert updated.review_state == :approved

      GenServer.stop(monitor)
    end

    test "only polls open PRs" do
      register_pr(number: 9006, review_state: :pending)

      merged_pr = PR.new(9007, "org/repo", review_state: :pending)
      {:ok, _} = Tracker.register(merged_pr)
      Tracker.update_pr("org/repo", 9007, state: :merged)

      # Only the open PR (9006) should be polled
      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 9006 -> {:ok, []} end)

      {:ok, monitor} =
        Monitor.start_link(
          name: :test_monitor_6,
          interval_ms: :timer.hours(1),
          auto_fixup: false
        )

      Monitor.poll_now(monitor)
      Process.sleep(50)

      GenServer.stop(monitor)
    end
  end

  describe "scheduled polling" do
    test "polls on configured interval" do
      register_pr(number: 9010, review_state: :pending)

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 9010 -> {:ok, []} end)

      {:ok, monitor} =
        Monitor.start_link(
          name: :test_monitor_scheduled,
          interval_ms: 50,
          auto_fixup: false
        )

      # Wait for at least one scheduled poll
      Process.sleep(100)

      GenServer.stop(monitor)
    end
  end

  describe "disabled by default" do
    test "monitor is not in supervision tree when disabled" do
      config = Application.get_env(:lattice, Lattice.PRs.Monitor, [])
      enabled = Keyword.get(config, :enabled, false)
      refute enabled
    end
  end
end
