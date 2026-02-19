defmodule Lattice.Policy.RepoProfile do
  @moduledoc """
  Per-repo configuration profile.

  Stores conventions, test commands, branch patterns, risk zones, and
  doc expectations for a specific repository. Used by the policy engine
  to make context-aware gating decisions.

  ## Storage

  Profiles are persisted via `Lattice.Store.ETS` under the `:repo_profiles`
  namespace, keyed by repo slug (e.g., `"plattegruber/lattice"`).
  """

  alias Lattice.Store.ETS, as: MetadataStore

  @namespace :repo_profiles

  @type t :: %__MODULE__{
          repo: String.t(),
          test_commands: [String.t()],
          branch_convention: map(),
          ci_checks: [String.t()],
          risk_zones: [String.t()],
          doc_paths: [String.t()],
          auto_approve_paths: [String.t()],
          settings: map()
        }

  defstruct [
    :repo,
    test_commands: [],
    branch_convention: %{main: "main", pr_prefix: ""},
    ci_checks: [],
    risk_zones: [],
    doc_paths: [],
    auto_approve_paths: [],
    settings: %{}
  ]

  # ── Public API ──────────────────────────────────────────────────

  @doc "Create or update a repo profile."
  @spec put(t()) :: :ok
  def put(%__MODULE__{repo: repo} = profile) when is_binary(repo) do
    MetadataStore.put(@namespace, repo, Map.from_struct(profile))
  end

  @doc "Fetch a repo profile by repo slug."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(repo) when is_binary(repo) do
    case MetadataStore.get(@namespace, repo) do
      {:ok, data} when is_map(data) ->
        {:ok, from_map(data)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "List all repo profiles."
  @spec list() :: {:ok, [t()]}
  def list do
    case MetadataStore.list(@namespace) do
      {:ok, items} ->
        profiles =
          items
          |> Enum.map(fn item ->
            data = if is_map(item), do: item, else: %{}
            from_map(data)
          end)
          |> Enum.sort_by(& &1.repo)

        {:ok, profiles}
    end
  end

  @doc "Delete a repo profile."
  @spec delete(String.t()) :: :ok
  def delete(repo) when is_binary(repo) do
    MetadataStore.delete(@namespace, repo)
  end

  @doc "Get or create a default profile for a repo."
  @spec get_or_default(String.t()) :: t()
  def get_or_default(repo) when is_binary(repo) do
    case get(repo) do
      {:ok, profile} -> profile
      {:error, :not_found} -> %__MODULE__{repo: repo}
    end
  end

  # ── Serialization ──────────────────────────────────────────────

  @doc false
  def from_map(data) when is_map(data) do
    %__MODULE__{
      repo: data[:repo] || data["repo"],
      test_commands: data[:test_commands] || data["test_commands"] || [],
      branch_convention:
        data[:branch_convention] || data["branch_convention"] || %{main: "main", pr_prefix: ""},
      ci_checks: data[:ci_checks] || data["ci_checks"] || [],
      risk_zones: data[:risk_zones] || data["risk_zones"] || [],
      doc_paths: data[:doc_paths] || data["doc_paths"] || [],
      auto_approve_paths: data[:auto_approve_paths] || data["auto_approve_paths"] || [],
      settings: data[:settings] || data["settings"] || %{}
    }
  end

  @doc "Serialize a profile to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    %{
      repo: profile.repo,
      test_commands: profile.test_commands,
      branch_convention: profile.branch_convention,
      ci_checks: profile.ci_checks,
      risk_zones: profile.risk_zones,
      doc_paths: profile.doc_paths,
      auto_approve_paths: profile.auto_approve_paths,
      settings: profile.settings
    }
  end
end
