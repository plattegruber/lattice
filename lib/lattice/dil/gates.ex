defmodule Lattice.DIL.Gates do
  @moduledoc """
  Safety gates for the Daily Improvement Loop.

  All gates must pass before DIL proceeds to context gathering and proposal.
  Each gate is a pure function that queries GitHub state via the configured
  capability module. If any gate fails, DIL skips with a reason.

  Gates:
  - `enabled?/0` — DIL feature flag is on
  - `open_dil_issue?/0` — no open issue with `dil-proposal` label
  - `cooldown_elapsed?/0` — most recent `dil-proposal` issue older than cooldown
  - `recent_rejection?/0` — no closed `dil-proposal` within rejection cooldown
  """

  alias Lattice.Capabilities.GitHub

  @dil_label "dil-proposal"

  @doc """
  Check all safety gates. Returns `{:ok, :gates_passed}` if all pass,
  or `{:skip, reason}` on the first failing gate.
  """
  @spec check_all() :: {:ok, :gates_passed} | {:skip, String.t()}
  def check_all do
    with :ok <- check_enabled(),
         :ok <- check_no_open_issue(),
         :ok <- check_cooldown_elapsed(),
         :ok <- check_no_recent_rejection() do
      {:ok, :gates_passed}
    end
  end

  @doc "Returns true if the DIL feature flag is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    dil_config()[:enabled] == true
  end

  @doc "Returns true if there is an open issue with the `dil-proposal` label."
  @spec open_dil_issue?() :: boolean()
  def open_dil_issue? do
    case GitHub.list_issues(labels: [@dil_label], state: "open") do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  @doc "Returns true if the most recent `dil-proposal` issue is older than the cooldown period."
  @spec cooldown_elapsed?() :: boolean()
  def cooldown_elapsed? do
    cooldown_hours = dil_config()[:cooldown_hours] || 24

    case GitHub.list_issues(labels: [@dil_label], state: "all", per_page: 1) do
      {:ok, [most_recent | _]} ->
        created_at = parse_datetime(most_recent["created_at"])
        hours_ago = DateTime.diff(DateTime.utc_now(), created_at, :hour)
        hours_ago >= cooldown_hours

      {:ok, []} ->
        # No previous DIL issues — cooldown trivially satisfied
        true

      {:error, _} ->
        # On error, fail closed (skip)
        false
    end
  end

  @doc "Returns true if a `dil-proposal` issue was closed within the rejection cooldown."
  @spec recent_rejection?() :: boolean()
  def recent_rejection? do
    rejection_hours = dil_config()[:rejection_cooldown_hours] || 48

    case GitHub.list_issues(labels: [@dil_label], state: "closed", per_page: 5) do
      {:ok, issues} ->
        Enum.any?(issues, fn issue ->
          closed_at = parse_datetime(issue["closed_at"])
          hours_ago = DateTime.diff(DateTime.utc_now(), closed_at, :hour)
          hours_ago < rejection_hours
        end)

      {:error, _} ->
        # On error, fail closed (assume rejection)
        true
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp check_enabled do
    if enabled?(), do: :ok, else: {:skip, "DIL is disabled"}
  end

  defp check_no_open_issue do
    if open_dil_issue?(), do: {:skip, "open DIL issue exists"}, else: :ok
  end

  defp check_cooldown_elapsed do
    if cooldown_elapsed?(), do: :ok, else: {:skip, "cooldown period has not elapsed"}
  end

  defp check_no_recent_rejection do
    if recent_rejection?(),
      do: {:skip, "recent DIL proposal was rejected"},
      else: :ok
  end

  defp dil_config, do: Application.get_env(:lattice, :dil, [])

  defp parse_datetime(nil), do: DateTime.add(DateTime.utc_now(), -999, :day)

  defp parse_datetime(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.add(DateTime.utc_now(), -999, :day)
    end
  end
end
