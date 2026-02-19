defmodule Lattice.PRs.Tracker do
  @moduledoc """
  ETS-backed GenServer that tracks pull requests created by Lattice.

  Maintains a table of `PR` structs indexed by `{repo, number}` and provides
  lookup functions by PR number, intent, and state. Subscribes to the
  `"artifacts"` PubSub topic to auto-register PRs when artifact links are
  created.

  ## PubSub Events

  State changes broadcast on the `"prs"` topic:

  - `{:pr_registered, pr}` — new PR tracked
  - `{:pr_updated, pr, changes}` — PR state changed (changes is a keyword of old→new)
  """

  use GenServer

  alias Lattice.PRs.PR

  @table :lattice_prs
  @by_intent_table :lattice_prs_by_intent

  # ── Public API ────────────────────────────────────────────────────

  @doc "Start the PR Tracker as a named GenServer."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a new PR for tracking.

  If the PR is already tracked, returns the existing record.
  Broadcasts `{:pr_registered, pr}` on the `"prs"` PubSub topic.
  """
  @spec register(PR.t()) :: {:ok, PR.t()}
  def register(%PR{} = pr) do
    GenServer.call(__MODULE__, {:register, pr})
  end

  @doc """
  Update a tracked PR's fields.

  Returns the updated PR and broadcasts `{:pr_updated, pr, changes}`.
  Returns `{:error, :not_found}` if the PR is not tracked.
  """
  @spec update_pr(String.t(), pos_integer(), keyword()) ::
          {:ok, PR.t()} | {:error, :not_found}
  def update_pr(repo, number, fields) do
    GenServer.call(__MODULE__, {:update, repo, number, fields})
  end

  @doc """
  Get a tracked PR by repo and number.
  """
  @spec get(String.t(), pos_integer()) :: PR.t() | nil
  def get(repo, number) do
    case :ets.lookup(@table, {repo, number}) do
      [{_key, pr}] -> pr
      [] -> nil
    end
  end

  @doc """
  Get all tracked PRs for an intent.
  """
  @spec for_intent(String.t()) :: [PR.t()]
  def for_intent(intent_id) when is_binary(intent_id) do
    case :ets.lookup(@by_intent_table, intent_id) do
      [] -> []
      entries -> Enum.map(entries, fn {_key, {repo, number}} -> get(repo, number) end)
    end
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Get all tracked PRs with a given state.
  """
  @spec by_state(PR.pr_state()) :: [PR.t()]
  def by_state(state) when state in [:open, :closed, :merged] do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, pr} -> pr end)
    |> Enum.filter(&(&1.state == state))
  end

  @doc """
  Get all tracked PRs that need attention.
  """
  @spec needs_attention() :: [PR.t()]
  def needs_attention do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, pr} -> pr end)
    |> Enum.filter(&PR.needs_attention?/1)
  end

  @doc """
  Return all tracked PRs.
  """
  @spec all() :: [PR.t()]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, pr} -> pr end)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@by_intent_table, [:named_table, :bag, :public, read_concurrency: true])

    # Subscribe to artifact events to auto-register PRs
    Lattice.Events.subscribe_artifacts()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, %PR{} = pr}, _from, state) do
    key = {pr.repo, pr.number}

    case :ets.lookup(@table, key) do
      [{_key, existing}] ->
        {:reply, {:ok, existing}, state}

      [] ->
        :ets.insert(@table, {key, pr})

        if pr.intent_id do
          :ets.insert(@by_intent_table, {pr.intent_id, {pr.repo, pr.number}})
        end

        emit_telemetry(:registered, pr)
        broadcast(:pr_registered, pr)

        {:reply, {:ok, pr}, state}
    end
  end

  @impl true
  def handle_call({:update, repo, number, fields}, _from, state) do
    key = {repo, number}

    case :ets.lookup(@table, key) do
      [{_key, existing}] ->
        changes = detect_changes(existing, fields)
        updated = PR.update(existing, fields)
        :ets.insert(@table, {key, updated})

        if changes != [] do
          emit_telemetry(:updated, updated)
          broadcast(:pr_updated, updated, changes)
        end

        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:artifact_registered, link}, state) do
    maybe_register_from_artifact(link, state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ──────────────────────────────────────────────────────

  defp maybe_register_from_artifact(%{kind: :pull_request, ref: ref} = link, state)
       when is_integer(ref) do
    repo = extract_repo(link)

    if repo do
      pr =
        PR.new(ref, repo,
          intent_id: link.intent_id,
          run_id: link.run_id,
          url: link.url,
          created_at: link.created_at
        )

      key = {pr.repo, pr.number}

      case :ets.lookup(@table, key) do
        [{_key, _existing}] ->
          :ok

        [] ->
          :ets.insert(@table, {key, pr})

          if pr.intent_id do
            :ets.insert(@by_intent_table, {pr.intent_id, {pr.repo, pr.number}})
          end

          emit_telemetry(:registered, pr)
          broadcast(:pr_registered, pr)
      end
    end

    {:noreply, state}
  end

  defp maybe_register_from_artifact(_link, state), do: {:noreply, state}

  defp extract_repo(%{url: url}) when is_binary(url) do
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/}, url) do
      [_, repo] -> repo
      _ -> default_repo()
    end
  end

  defp extract_repo(_link), do: default_repo()

  defp default_repo do
    Application.get_env(:lattice, :resources, [])
    |> Keyword.get(:github_repo)
  end

  defp detect_changes(existing, fields) do
    Enum.reduce(fields, [], fn {field, new_value}, acc ->
      old_value = Map.get(existing, field)

      if old_value != new_value do
        [{field, old_value, new_value} | acc]
      else
        acc
      end
    end)
  end

  defp emit_telemetry(event, pr) do
    :telemetry.execute(
      [:lattice, :pr, event],
      %{count: 1},
      %{repo: pr.repo, number: pr.number, state: pr.state, review_state: pr.review_state}
    )
  end

  defp broadcast(event, pr, changes \\ []) do
    message =
      case changes do
        [] -> {event, pr}
        changes -> {event, pr, changes}
      end

    Phoenix.PubSub.broadcast(Lattice.PubSub, Lattice.Events.prs_topic(), message)
  end
end
