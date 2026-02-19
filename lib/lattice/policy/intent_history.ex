defmodule Lattice.Policy.IntentHistory do
  @moduledoc """
  Computes intent history summaries per repo or sprite.

  Queries the intent store and aggregates success/failure rates,
  common kinds, and patterns to inform policy decisions.
  """

  alias Lattice.Intents.Store

  @type summary :: %{
          repo: String.t(),
          total: non_neg_integer(),
          completed: non_neg_integer(),
          failed: non_neg_integer(),
          by_kind: map(),
          by_state: map(),
          success_rate: float()
        }

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Compute a summary of all intents targeting a specific repo.
  """
  @spec repo_summary(String.t()) :: summary()
  def repo_summary(repo) when is_binary(repo) do
    {:ok, intents} = Store.list()

    repo_intents =
      Enum.filter(intents, fn i ->
        Map.get(i.payload, "repo") == repo
      end)

    build_summary(repo, repo_intents)
  end

  @doc """
  Compute a summary of all intents for a specific sprite.
  """
  @spec sprite_summary(String.t()) :: summary()
  def sprite_summary(sprite_name) when is_binary(sprite_name) do
    {:ok, intents} = Store.list()

    sprite_intents =
      Enum.filter(intents, fn i ->
        source_sprite?(i, sprite_name) or payload_sprite?(i, sprite_name)
      end)

    build_summary(sprite_name, sprite_intents)
  end

  @doc """
  Compute summaries for all repos that have intents.
  """
  @spec all_repo_summaries() :: [summary()]
  def all_repo_summaries do
    {:ok, intents} = Store.list()

    intents
    |> Enum.filter(fn i -> Map.has_key?(i.payload, "repo") end)
    |> Enum.group_by(fn i -> i.payload["repo"] end)
    |> Enum.map(fn {repo, repo_intents} -> build_summary(repo, repo_intents) end)
    |> Enum.sort_by(& &1.total, :desc)
  end

  # ── Private ─────────────────────────────────────────────────────

  defp build_summary(key, intents) do
    total = length(intents)
    completed = Enum.count(intents, &(&1.state == :completed))
    failed = Enum.count(intents, &(&1.state == :failed))

    by_kind =
      intents
      |> Enum.group_by(& &1.kind)
      |> Map.new(fn {k, v} -> {to_string(k), length(v)} end)

    by_state =
      intents
      |> Enum.group_by(& &1.state)
      |> Map.new(fn {k, v} -> {to_string(k), length(v)} end)

    success_rate = if total > 0, do: completed / total, else: 0.0

    %{
      repo: key,
      total: total,
      completed: completed,
      failed: failed,
      by_kind: by_kind,
      by_state: by_state,
      success_rate: Float.round(success_rate, 3)
    }
  end

  defp source_sprite?(%{source: %{type: :sprite, id: id}}, name), do: id == name
  defp source_sprite?(_, _), do: false

  defp payload_sprite?(%{payload: payload}, name) do
    Map.get(payload, "sprite_name") == name or Map.get(payload, "sprite_id") == name
  end
end
