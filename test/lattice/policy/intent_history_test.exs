defmodule Lattice.Policy.IntentHistoryTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store
  alias Lattice.Policy.IntentHistory

  defp create_intent(repo, opts \\ []) do
    source = Keyword.get(opts, :source, %{type: :system, id: "test"})
    state = Keyword.get(opts, :final_state, nil)

    {:ok, intent} =
      Intent.new(:health_detect, source,
        summary: "test for #{repo}",
        payload: %{
          "repo" => repo,
          "observation_type" => "anomaly",
          "severity" => "high",
          "sprite_id" => Keyword.get(opts, :sprite_name, "test-sprite")
        }
      )

    {:ok, stored} = Store.create(intent)

    if state do
      case state do
        :completed ->
          Store.update(stored.id, %{state: :classified})
          Store.update(stored.id, %{state: :approved, actor: "test"})
          Store.update(stored.id, %{state: :running})
          Store.update(stored.id, %{state: :completed})

        :failed ->
          Store.update(stored.id, %{state: :classified})
          Store.update(stored.id, %{state: :approved, actor: "test"})
          Store.update(stored.id, %{state: :running})
          Store.update(stored.id, %{state: :failed})

        _ ->
          :ok
      end
    end

    stored
  end

  describe "repo_summary/1" do
    test "computes summary for a repo" do
      create_intent("test/hist-repo", final_state: :completed)
      create_intent("test/hist-repo", final_state: :completed)
      create_intent("test/hist-repo", final_state: :failed)

      summary = IntentHistory.repo_summary("test/hist-repo")
      assert summary.total == 3
      assert summary.completed == 2
      assert summary.failed == 1
      assert summary.success_rate > 0.0
      assert Map.has_key?(summary.by_kind, "health_detect")
    end

    test "returns zero summary for unknown repo" do
      summary = IntentHistory.repo_summary("test/no-intents-here")
      assert summary.total == 0
      assert summary.completed == 0
      assert summary.success_rate == 0.0
    end
  end

  describe "sprite_summary/1" do
    test "finds intents by sprite_id in payload" do
      create_intent("test/sprite-hist", sprite_name: "test-sprite-hist")

      summary = IntentHistory.sprite_summary("test-sprite-hist")
      assert summary.total >= 1
    end

    test "finds intents by source sprite" do
      source = %{type: :sprite, id: "test-src-sprite"}
      create_intent("test/src-repo", source: source)

      summary = IntentHistory.sprite_summary("test-src-sprite")
      assert summary.total >= 1
    end
  end

  describe "all_repo_summaries/0" do
    test "returns summaries grouped by repo" do
      create_intent("test/all-a")
      create_intent("test/all-b")
      create_intent("test/all-b")

      summaries = IntentHistory.all_repo_summaries()
      repos = Enum.map(summaries, & &1.repo)
      assert "test/all-a" in repos
      assert "test/all-b" in repos

      b_summary = Enum.find(summaries, &(&1.repo == "test/all-b"))
      assert b_summary.total >= 2
    end

    test "sorts by total descending" do
      summaries = IntentHistory.all_repo_summaries()
      totals = Enum.map(summaries, & &1.total)
      assert totals == Enum.sort(totals, :desc)
    end
  end
end
