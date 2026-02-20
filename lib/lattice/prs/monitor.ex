defmodule Lattice.PRs.Monitor do
  @moduledoc """
  GenServer that periodically polls open PRs tracked by Lattice and detects
  review state changes.

  When a PR transitions to `:changes_requested`, the Monitor auto-proposes
  a `pr_fixup` intent via the Pipeline. When a PR is approved with passing CI,
  the Monitor updates the tracker so downstream logic can decide on merging.

  ## Configuration

      config :lattice, Lattice.PRs.Monitor,
        enabled: true,
        interval_ms: 60_000,
        auto_fixup_on_review: true

  The Monitor is disabled by default and must be explicitly enabled.
  """

  use GenServer

  require Logger

  alias Lattice.Capabilities.GitHub
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.PRs.PR
  alias Lattice.PRs.Tracker

  @default_interval_ms 60_000

  defstruct [:interval_ms, :auto_fixup, :timer_ref]

  # ── Public API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Trigger an immediate poll cycle (useful for testing).
  """
  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server \\ __MODULE__) do
    GenServer.cast(server, :poll_now)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────

  @impl true
  def init(opts) do
    config = Application.get_env(:lattice, __MODULE__, [])

    interval_ms =
      Keyword.get(opts, :interval_ms, Keyword.get(config, :interval_ms, @default_interval_ms))

    auto_fixup = Keyword.get(opts, :auto_fixup, Keyword.get(config, :auto_fixup_on_review, true))

    state = %__MODULE__{
      interval_ms: interval_ms,
      auto_fixup: auto_fixup,
      timer_ref: nil
    }

    {:ok, schedule_poll(state)}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    do_poll(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll(state)
    {:noreply, schedule_poll(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ──────────────────────────────────────────────────────

  defp schedule_poll(%__MODULE__{interval_ms: interval} = state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :poll, interval)
    %{state | timer_ref: ref}
  end

  defp do_poll(state) do
    open_prs = Tracker.by_state(:open)

    Enum.each(open_prs, fn pr ->
      check_pr(pr, state)
    end)
  end

  defp check_pr(%PR{} = pr, state) do
    with {:ok, new_review_state} <- fetch_review_state(pr),
         true <- new_review_state != pr.review_state do
      handle_review_state_change(pr, new_review_state, state)
    end
  end

  defp handle_review_state_change(pr, new_review_state, state) do
    Logger.info(
      "PR ##{pr.number} (#{pr.repo}) review state changed: #{pr.review_state} -> #{new_review_state}"
    )

    Tracker.update_pr(pr.repo, pr.number, review_state: new_review_state)

    if new_review_state == :changes_requested and state.auto_fixup do
      propose_fixup(pr)
    end
  end

  defp fetch_review_state(%PR{number: pr_number}) do
    case GitHub.list_reviews(pr_number) do
      {:ok, reviews} ->
        {:ok, derive_review_state(reviews)}

      {:error, reason} ->
        Logger.warning("Failed to fetch reviews for PR ##{pr_number}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp derive_review_state([]), do: :pending

  defp derive_review_state(reviews) do
    # Group by reviewer, take the latest review per reviewer
    latest_by_reviewer =
      reviews
      |> Enum.group_by(& &1["user"]["login"])
      |> Enum.map(fn {_user, user_reviews} ->
        Enum.max_by(user_reviews, & &1["submitted_at"], fn -> nil end)
      end)
      |> Enum.reject(&is_nil/1)

    states = Enum.map(latest_by_reviewer, & &1["state"])

    cond do
      "CHANGES_REQUESTED" in states -> :changes_requested
      "APPROVED" in states -> :approved
      "COMMENTED" in states -> :commented
      true -> :pending
    end
  end

  defp propose_fixup(%PR{} = pr) do
    pr_url = pr.url || "https://github.com/#{pr.repo}/pull/#{pr.number}"

    case Intent.new(:pr_fixup, %{type: :pr_monitor, id: "monitor_#{pr.number}"},
           summary: "Auto-fixup for review feedback on PR ##{pr.number}",
           payload: %{
             "pr_url" => pr_url,
             "feedback" =>
               "Changes requested on PR ##{pr.number}. Please address the review feedback.",
             "pr_title" => pr.title || "PR ##{pr.number}",
             "reviewer" => "auto-detected"
           },
           affected_resources: ["repo:#{pr.repo}", "pr:#{pr.number}"]
         ) do
      {:ok, intent} ->
        case Pipeline.propose(intent) do
          {:ok, proposed} ->
            Logger.info("Proposed fixup intent #{proposed.id} for PR ##{pr.number}")

          {:error, reason} ->
            Logger.warning("Failed to propose fixup for PR ##{pr.number}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to build fixup intent for PR ##{pr.number}: #{inspect(reason)}")
    end
  end
end
