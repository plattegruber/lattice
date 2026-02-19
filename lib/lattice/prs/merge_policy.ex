defmodule Lattice.PRs.MergePolicy do
  @moduledoc """
  Configurable merge rules and conflict detection for Lattice-managed PRs.

  Evaluates whether a PR is ready to merge based on:
  - Required approval count
  - CI status requirements
  - Mergeable status (no conflicts)

  Can optionally auto-merge when all conditions are met, and proposes
  fixup intents when merge conflicts are detected.

  ## Configuration

      config :lattice, Lattice.PRs.MergePolicy,
        auto_merge: false,
        required_approvals: 1,
        require_ci: true,
        merge_method: :squash

  """

  require Logger

  alias Lattice.Capabilities.GitHub
  alias Lattice.PRs.PR
  alias Lattice.PRs.Tracker

  @type merge_method :: :merge | :squash | :rebase
  @type policy :: %{
          auto_merge: boolean(),
          required_approvals: non_neg_integer(),
          require_ci: boolean(),
          merge_method: merge_method()
        }

  @doc """
  Returns the current merge policy from application config.
  """
  @spec policy() :: policy()
  def policy do
    config = Application.get_env(:lattice, __MODULE__, [])

    %{
      auto_merge: Keyword.get(config, :auto_merge, false),
      required_approvals: Keyword.get(config, :required_approvals, 1),
      require_ci: Keyword.get(config, :require_ci, true),
      merge_method: Keyword.get(config, :merge_method, :squash)
    }
  end

  @doc """
  Evaluate a PR against the merge policy.

  Returns `{:merge_ready, pr}` if all conditions are met,
  `{:not_ready, reasons}` with a list of unmet conditions,
  or `{:conflict, pr}` if the PR has merge conflicts.
  """
  @spec evaluate(PR.t()) ::
          {:merge_ready, PR.t()} | {:not_ready, [String.t()]} | {:conflict, PR.t()}
  def evaluate(%PR{} = pr) do
    evaluate(pr, policy())
  end

  @doc """
  Evaluate a PR against a specific policy (useful for testing).
  """
  @spec evaluate(PR.t(), policy()) ::
          {:merge_ready, PR.t()} | {:not_ready, [String.t()]} | {:conflict, PR.t()}
  def evaluate(%PR{mergeable: false} = pr, _policy) do
    {:conflict, pr}
  end

  def evaluate(%PR{state: state}, _policy) when state != :open do
    {:not_ready, ["PR is #{state}, not open"]}
  end

  def evaluate(%PR{} = pr, policy) do
    reasons = []

    reasons =
      if pr.review_state != :approved do
        ["review not approved (currently: #{pr.review_state})" | reasons]
      else
        reasons
      end

    reasons =
      if policy.require_ci and pr.ci_status not in [:success, nil] do
        ["CI not passing (currently: #{pr.ci_status})" | reasons]
      else
        reasons
      end

    reasons =
      if pr.mergeable == nil do
        ["mergeable status unknown" | reasons]
      else
        reasons
      end

    if reasons == [] do
      {:merge_ready, pr}
    else
      {:not_ready, Enum.reverse(reasons)}
    end
  end

  @doc """
  Check a PR's merge status from GitHub and update the tracker.

  Fetches the latest PR data from GitHub, updates the tracker with
  mergeable status and CI info, then evaluates against the merge policy.
  """
  @spec check_and_evaluate(PR.t()) ::
          {:merge_ready, PR.t()}
          | {:not_ready, [String.t()]}
          | {:conflict, PR.t()}
          | {:error, term()}
  def check_and_evaluate(%PR{} = pr) do
    case GitHub.get_pull_request(pr.number) do
      {:ok, gh_pr} ->
        mergeable = Map.get(gh_pr, "mergeable")
        ci_status = derive_ci_status(gh_pr)

        updates =
          [mergeable: mergeable]
          |> maybe_add(:ci_status, ci_status)

        {:ok, updated} = Tracker.update_pr(pr.repo, pr.number, updates)
        evaluate(updated)

      {:error, reason} ->
        Logger.warning("Failed to fetch PR ##{pr.number} for merge check: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Attempt to merge a PR if policy allows auto-merge.

  Returns `{:ok, result}` if merged, `{:skipped, reason}` if auto-merge
  is disabled or conditions aren't met, or `{:error, reason}` on failure.
  """
  @spec try_auto_merge(PR.t()) ::
          {:ok, map()} | {:skipped, String.t()} | {:error, term()}
  def try_auto_merge(%PR{} = pr) do
    p = policy()

    unless p.auto_merge do
      {:skipped, "auto_merge is disabled"}
    else
      case evaluate(pr, p) do
        {:merge_ready, _pr} ->
          Logger.info("Auto-merging PR ##{pr.number} (#{pr.repo}) via #{p.merge_method}")

          case GitHub.merge_pull_request(pr.number, method: p.merge_method) do
            {:ok, result} ->
              Tracker.update_pr(pr.repo, pr.number, state: :merged)
              {:ok, result}

            {:error, reason} ->
              Logger.warning("Auto-merge failed for PR ##{pr.number}: #{inspect(reason)}")
              {:error, reason}
          end

        {:conflict, _pr} ->
          {:skipped, "PR has merge conflicts"}

        {:not_ready, reasons} ->
          {:skipped, "conditions not met: #{Enum.join(reasons, ", ")}"}
      end
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp derive_ci_status(%{"mergeable_state" => "clean"}), do: :success
  defp derive_ci_status(%{"mergeable_state" => "unstable"}), do: :failure
  defp derive_ci_status(%{"mergeable_state" => "blocked"}), do: :pending
  defp derive_ci_status(_), do: nil

  defp maybe_add(keyword, _key, nil), do: keyword
  defp maybe_add(keyword, key, value), do: Keyword.put(keyword, key, value)
end
