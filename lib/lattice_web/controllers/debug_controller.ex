defmodule LatticeWeb.DebugController do
  @moduledoc """
  Unauthenticated debug endpoint for production observability.

  Returns operational metrics and system state — no sensitive data.
  Used by the Claude Code "in-production" skill to understand
  what is currently deployed and running.
  """
  use LatticeWeb, :controller

  alias Lattice.Instance
  alias Lattice.Intents.Store
  alias Lattice.PRs.Tracker
  alias Lattice.Sprites.FleetManager

  def index(conn, _params) do
    json(conn, %{
      system: system_info(),
      fleet: fleet_info(),
      intents: intent_info(),
      prs: pr_info(),
      instance: Instance.identity(),
      timestamp: DateTime.utc_now()
    })
  end

  defp system_info do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    memory = :erlang.memory()

    %{
      elixir_version: System.version(),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      uptime_seconds: div(uptime_ms, 1000),
      process_count: :erlang.system_info(:process_count),
      memory_mb: %{
        total: Float.round(memory[:total] / 1_048_576, 1),
        processes: Float.round(memory[:processes] / 1_048_576, 1),
        ets: Float.round(memory[:ets] / 1_048_576, 1)
      },
      schedulers: :erlang.system_info(:schedulers_online)
    }
  end

  defp fleet_info do
    summary = FleetManager.fleet_summary()

    %{
      total: summary.total,
      by_state: Map.new(summary.by_state, fn {k, v} -> {Atom.to_string(k), v} end)
    }
  rescue
    _ -> %{total: 0, by_state: %{}, error: "fleet_manager_unavailable"}
  end

  defp intent_info do
    all = Store.list()

    by_state =
      Enum.group_by(all, & &1.state)
      |> Map.new(fn {state, intents} -> {Atom.to_string(state), length(intents)} end)

    by_kind =
      Enum.group_by(all, & &1.kind)
      |> Map.new(fn {kind, intents} -> {Atom.to_string(kind), length(intents)} end)

    recent =
      all
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(5)
      |> Enum.map(fn i ->
        %{
          id: i.id,
          kind: i.kind,
          state: i.state,
          summary: i.summary,
          updated_at: i.updated_at
        }
      end)

    %{total: length(all), by_state: by_state, by_kind: by_kind, recent: recent}
  rescue
    _ -> %{total: 0, by_state: %{}, by_kind: %{}, recent: [], error: "store_unavailable"}
  end

  defp pr_info do
    open = Tracker.by_state(:open)
    merged = Tracker.by_state(:merged)

    %{
      open: length(open),
      merged: length(merged),
      open_prs:
        Enum.map(open, fn pr ->
          %{
            number: pr.number,
            repo: pr.repo,
            review_state: pr.review_state,
            ci_status: pr.ci_status,
            mergeable: pr.mergeable
          }
        end)
    }
  rescue
    _ -> %{open: 0, merged: 0, open_prs: [], error: "tracker_unavailable"}
  end
end
