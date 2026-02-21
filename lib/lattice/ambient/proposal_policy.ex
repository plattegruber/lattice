defmodule Lattice.Ambient.ProposalPolicy do
  @moduledoc """
  Policy checks on a sprite's handoff proposal.

  Examines the list of changed files and proposal flags to decide whether
  the proposal should be accepted, accepted with warnings, or rejected.
  """

  alias Lattice.Ambient.Proposal

  @doc """
  Check a proposal against policy rules.

  `diff_names` is a list of file paths changed in the proposal (from `git diff --name-only`).

  Returns `{:ok, warnings}` where `warnings` is a (possibly empty) list of
  warning strings, or `{:error, :policy_violation}` if forbidden files are touched.
  """
  @spec check(Proposal.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, :policy_violation}
  def check(%Proposal{} = proposal, diff_names) when is_list(diff_names) do
    case check_forbidden(diff_names) do
      [] -> {:ok, collect_warnings(proposal, diff_names)}
      _forbidden -> {:error, :policy_violation}
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp forbidden_patterns do
    [
      ~r/\.env$/,
      ~r/\.env\./,
      ~r/\.pem$/,
      ~r/\.key$/,
      ~r/credentials/i,
      ~r/secrets?\.(ya?ml|json|toml)$/i
    ]
  end

  defp check_forbidden(diff_names) do
    Enum.filter(diff_names, fn path ->
      Enum.any?(forbidden_patterns(), &Regex.match?(&1, path))
    end)
  end

  defp collect_warnings(proposal, diff_names) do
    []
    |> maybe_warn_deps(proposal, diff_names)
    |> maybe_warn_migrations(proposal, diff_names)
    |> maybe_warn_auth(proposal)
    |> maybe_warn_failed_commands(proposal)
  end

  defp maybe_warn_deps(warnings, %{flags: %{"touches_deps" => true}}, diff_names) do
    if Enum.any?(diff_names, &String.ends_with?(&1, "mix.exs")) do
      ["Proposal modifies dependencies (mix.exs changed, touches_deps flag set)" | warnings]
    else
      warnings
    end
  end

  defp maybe_warn_deps(warnings, _, _), do: warnings

  defp maybe_warn_migrations(warnings, %{flags: %{"touches_migrations" => true}}, diff_names) do
    if Enum.any?(diff_names, &String.contains?(&1, "priv/repo/migrations")) do
      ["Proposal includes database migrations" | warnings]
    else
      warnings
    end
  end

  defp maybe_warn_migrations(warnings, _, _), do: warnings

  defp maybe_warn_auth(warnings, %{flags: %{"touches_auth" => true}}) do
    ["Proposal touches authentication code" | warnings]
  end

  defp maybe_warn_auth(warnings, _), do: warnings

  defp maybe_warn_failed_commands(warnings, %{commands: commands}) when is_list(commands) do
    failed =
      Enum.filter(commands, fn
        %{"exit" => code} when code != 0 -> true
        _ -> false
      end)

    case failed do
      [] -> warnings
      cmds -> ["#{length(cmds)} command(s) exited with non-zero status" | warnings]
    end
  end

  defp maybe_warn_failed_commands(warnings, _), do: warnings
end
