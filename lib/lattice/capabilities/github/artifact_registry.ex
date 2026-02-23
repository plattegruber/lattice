defmodule Lattice.Capabilities.GitHub.ArtifactRegistry do
  @moduledoc """
  ETS-backed registry for bidirectional GitHub artifact associations.

  Stores `ArtifactLink` structs and provides forward lookups (intent → artifacts)
  and reverse lookups (GitHub ref → intents). This enables tracing from any GitHub
  entity back to the intent that created it, and from any intent to all GitHub
  artifacts it produced.

  ## Indices

  The registry maintains three ETS tables:

  - **Primary** — stores links keyed by `{kind, ref}` (supports reverse lookup)
  - **By Intent** — bag table indexed by `intent_id` (supports forward lookup)
  - **By Run** — bag table indexed by `run_id` (supports run-scoped lookup)
  """

  use GenServer

  alias Lattice.Capabilities.GitHub.ArtifactLink

  @primary_table :artifact_links
  @by_intent_table :artifact_links_by_intent
  @by_run_table :artifact_links_by_run

  # ── Public API ────────────────────────────────────────────────────

  @doc "Start the ArtifactRegistry as a named GenServer."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a new artifact link.

  Emits `[:lattice, :artifact, :registered]` telemetry and broadcasts
  `{:artifact_registered, link}` on the `"artifacts"` PubSub topic.

  Returns `{:ok, link}`.
  """
  @spec register(ArtifactLink.t()) :: {:ok, ArtifactLink.t()}
  def register(%ArtifactLink{} = link) do
    GenServer.call(__MODULE__, {:register, link})
  end

  @doc """
  Look up all artifact links for an intent.

  Returns a list of `ArtifactLink` structs (possibly empty).
  """
  @spec lookup_by_intent(String.t()) :: [ArtifactLink.t()]
  def lookup_by_intent(intent_id) when is_binary(intent_id) do
    case :ets.lookup(@by_intent_table, intent_id) do
      [] -> []
      entries -> Enum.map(entries, fn {_key, link} -> link end)
    end
  end

  @doc """
  Reverse lookup: find all artifact links for a GitHub reference.

  For example, `lookup_by_ref(:issue, 42)` returns all links where
  `kind == :issue` and `ref == 42`.

  Returns a list of `ArtifactLink` structs (possibly empty).
  """
  @spec lookup_by_ref(ArtifactLink.kind(), String.t() | integer()) :: [ArtifactLink.t()]
  def lookup_by_ref(kind, ref) when kind in [:issue, :pull_request, :branch, :commit] do
    case :ets.lookup(@primary_table, {kind, ref}) do
      [] -> []
      entries -> Enum.map(entries, fn {_key, link} -> link end)
    end
  end

  @doc """
  Look up all artifact links for a run.

  Returns a list of `ArtifactLink` structs (possibly empty).
  """
  @spec lookup_by_run(String.t()) :: [ArtifactLink.t()]
  def lookup_by_run(run_id) when is_binary(run_id) do
    case :ets.lookup(@by_run_table, run_id) do
      [] -> []
      entries -> Enum.map(entries, fn {_key, link} -> link end)
    end
  end

  @doc """
  Clear all artifact links from the registry. Intended for use in tests only.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@primary_table)
    :ets.delete_all_objects(@by_intent_table)
    :ets.delete_all_objects(@by_run_table)
    :ok
  end

  @doc """
  Return all registered artifact links.
  """
  @spec all() :: [ArtifactLink.t()]
  def all do
    @by_intent_table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, link} -> link end)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@primary_table, [:named_table, :bag, :public, read_concurrency: true])
    :ets.new(@by_intent_table, [:named_table, :bag, :public, read_concurrency: true])
    :ets.new(@by_run_table, [:named_table, :bag, :public, read_concurrency: true])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, %ArtifactLink{} = link}, _from, state) do
    # Insert into all three indices
    :ets.insert(@primary_table, {{link.kind, link.ref}, link})
    :ets.insert(@by_intent_table, {link.intent_id, link})

    if link.run_id do
      :ets.insert(@by_run_table, {link.run_id, link})
    end

    # Emit telemetry
    :telemetry.execute(
      [:lattice, :artifact, :registered],
      %{count: 1},
      %{kind: link.kind, role: link.role, intent_id: link.intent_id}
    )

    # Broadcast for LiveView subscribers
    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "artifacts",
      {:artifact_registered, link}
    )

    {:reply, {:ok, link}, state}
  end
end
