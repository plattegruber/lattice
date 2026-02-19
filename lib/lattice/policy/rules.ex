defmodule Lattice.Policy.Rules do
  @moduledoc """
  Evaluates policy rules against intents to determine gating decisions.

  Rules are evaluated in order. The first matching rule determines the outcome.
  If no rule matches, the default behavior from `Safety.Gate` applies.

  ## Rule Types

  - `:path_auto_approve` — auto-approve intents that only touch allowed paths
  - `:time_gate` — restrict dangerous operations to specific hours
  - `:repo_override` — per-repo classification overrides

  ## Configuration

      config :lattice, Lattice.Policy.Rules,
        rules: [
          %{type: :path_auto_approve, paths: ["README.md", "docs/"]},
          %{type: :time_gate, deny_outside: {9, 17}, timezone: "America/Chicago"},
          %{type: :repo_override, repo: "org/repo", classification: :safe}
        ]
  """

  require Logger

  alias Lattice.Intents.Intent
  alias Lattice.Policy.RepoProfile

  @type decision :: :allow | :deny | :no_match

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Evaluate all policy rules against an intent.

  Returns `:allow` if a rule explicitly permits the intent,
  `:deny` if a rule blocks it, or `:no_match` if no rules apply
  (allowing the default Gate behavior).
  """
  @spec evaluate(Intent.t()) :: decision()
  def evaluate(%Intent{} = intent) do
    rules = config(:rules, [])

    Enum.reduce_while(rules, :no_match, fn rule, _acc ->
      case evaluate_rule(rule, intent) do
        :no_match -> {:cont, :no_match}
        decision -> {:halt, decision}
      end
    end)
  end

  @doc """
  Check if a specific path is in a repo's auto-approve list.
  """
  @spec path_auto_approved?(String.t(), String.t()) :: boolean()
  def path_auto_approved?(repo, path) when is_binary(repo) and is_binary(path) do
    profile = RepoProfile.get_or_default(repo)

    Enum.any?(profile.auto_approve_paths, fn allowed ->
      path_matches?(path, allowed)
    end)
  end

  @doc """
  Check if a path is in a repo's risk zones.
  """
  @spec path_in_risk_zone?(String.t(), String.t()) :: boolean()
  def path_in_risk_zone?(repo, path) when is_binary(repo) and is_binary(path) do
    profile = RepoProfile.get_or_default(repo)

    Enum.any?(profile.risk_zones, fn zone ->
      path_matches?(path, zone)
    end)
  end

  @doc "Returns the currently configured rules."
  @spec list_rules() :: [map()]
  def list_rules do
    config(:rules, [])
  end

  # ── Rule Evaluation ─────────────────────────────────────────────

  defp evaluate_rule(%{type: :path_auto_approve, paths: paths}, %Intent{} = intent) do
    affected = intent.affected_resources || []

    file_paths =
      affected
      |> Enum.filter(&String.starts_with?(&1, "file:"))
      |> Enum.map(&String.trim_leading(&1, "file:"))

    if file_paths != [] and Enum.all?(file_paths, fn fp -> path_in_list?(fp, paths) end) do
      :allow
    else
      :no_match
    end
  end

  defp evaluate_rule(%{type: :time_gate, deny_outside: {start_h, end_h}}, %Intent{} = intent) do
    if intent.classification in [:dangerous, :controlled] do
      hour = DateTime.utc_now().hour

      if hour >= start_h and hour < end_h do
        :no_match
      else
        Logger.info("Policy time gate: blocking #{intent.id} outside hours #{start_h}-#{end_h}")
        :deny
      end
    else
      :no_match
    end
  end

  defp evaluate_rule(%{type: :repo_override, repo: repo, allow: true}, %Intent{} = intent) do
    if intent_targets_repo?(intent, repo), do: :allow, else: :no_match
  end

  defp evaluate_rule(%{type: :repo_override, repo: repo, deny: true}, %Intent{} = intent) do
    if intent_targets_repo?(intent, repo), do: :deny, else: :no_match
  end

  defp evaluate_rule(rule, _intent) do
    Logger.debug("Unknown policy rule type: #{inspect(rule)}")
    :no_match
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp path_in_list?(path, allowed_paths) do
    Enum.any?(allowed_paths, &path_matches?(path, &1))
  end

  defp path_matches?(path, pattern) do
    cond do
      String.ends_with?(pattern, "/") ->
        String.starts_with?(path, pattern)

      String.contains?(pattern, "*") ->
        regex = pattern |> Regex.escape() |> String.replace("\\*", ".*")
        Regex.match?(~r/^#{regex}$/, path)

      true ->
        path == pattern
    end
  end

  defp intent_targets_repo?(%Intent{payload: payload}, repo) do
    Map.get(payload, "repo") == repo
  end

  # ── Config ──────────────────────────────────────────────────────

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
