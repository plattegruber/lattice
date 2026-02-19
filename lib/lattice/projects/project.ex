defmodule Lattice.Projects.Project do
  @moduledoc """
  A project represents a high-level initiative that decomposes into
  epics and tasks. Projects track progress across multiple intents
  and provide rollup summaries.

  ## Storage

  Projects are persisted via `Lattice.Store.ETS` under the `:projects`
  namespace, keyed by project ID.
  """

  alias Lattice.Store.ETS, as: MetadataStore

  @namespace :projects

  @type task :: %{
          id: String.t(),
          description: String.t(),
          intent_id: String.t() | nil,
          status: :pending | :in_progress | :completed | :blocked,
          blocks: [String.t()],
          blocked_by: [String.t()]
        }

  @type epic :: %{
          id: String.t(),
          title: String.t(),
          description: String.t(),
          tasks: [task()]
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          repo: String.t() | nil,
          seed_issue_url: String.t() | nil,
          epics: [epic()],
          metadata: map(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :name,
    :description,
    :repo,
    :seed_issue_url,
    :created_at,
    :updated_at,
    epics: [],
    metadata: %{}
  ]

  # ── Public API ──────────────────────────────────────────────────

  @doc "Create a new project."
  @spec create(String.t(), String.t(), keyword()) :: {:ok, t()}
  def create(name, description, opts \\ []) do
    now = DateTime.utc_now()

    project = %__MODULE__{
      id: generate_id(),
      name: name,
      description: description,
      repo: Keyword.get(opts, :repo),
      seed_issue_url: Keyword.get(opts, :seed_issue_url),
      epics: Keyword.get(opts, :epics, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: now,
      updated_at: now
    }

    save(project)
    {:ok, project}
  end

  @doc "Get a project by ID."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(id) do
    case MetadataStore.get(@namespace, id) do
      {:ok, data} -> {:ok, from_map(data)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "List all projects."
  @spec list() :: {:ok, [t()]}
  def list do
    case MetadataStore.list(@namespace) do
      {:ok, items} ->
        projects = Enum.map(items, &from_map/1)
        {:ok, projects}
    end
  end

  @doc "Update a project."
  @spec update(String.t(), map()) :: {:ok, t()} | {:error, :not_found}
  def update(id, attrs) do
    case get(id) do
      {:ok, project} ->
        updated =
          project
          |> maybe_update(:name, attrs)
          |> maybe_update(:description, attrs)
          |> maybe_update(:epics, attrs)
          |> maybe_update(:metadata, attrs)
          |> Map.put(:updated_at, DateTime.utc_now())

        save(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc "Delete a project."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    MetadataStore.delete(@namespace, id)
  end

  @doc "Add an epic to a project."
  @spec add_epic(String.t(), String.t(), String.t(), [task()]) ::
          {:ok, t()} | {:error, :not_found}
  def add_epic(project_id, title, description, tasks \\ []) do
    case get(project_id) do
      {:ok, project} ->
        epic = %{
          id: generate_id(),
          title: title,
          description: description,
          tasks: tasks
        }

        updated = %{project | epics: project.epics ++ [epic], updated_at: DateTime.utc_now()}
        save(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc "Add a task to an epic within a project."
  @spec add_task(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def add_task(project_id, epic_id, description, opts \\ []) do
    case get(project_id) do
      {:ok, project} ->
        task = %{
          id: generate_id(),
          description: description,
          intent_id: Keyword.get(opts, :intent_id),
          status: :pending,
          blocks: Keyword.get(opts, :blocks, []),
          blocked_by: Keyword.get(opts, :blocked_by, [])
        }

        epics =
          Enum.map(project.epics, fn epic ->
            if epic.id == epic_id do
              %{epic | tasks: epic.tasks ++ [task]}
            else
              epic
            end
          end)

        updated = %{project | epics: epics, updated_at: DateTime.utc_now()}
        save(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc "Compute progress for a project."
  @spec progress(t()) :: %{
          total_tasks: non_neg_integer(),
          completed: non_neg_integer(),
          in_progress: non_neg_integer(),
          blocked: non_neg_integer(),
          pending: non_neg_integer(),
          percent: float()
        }
  def progress(%__MODULE__{epics: epics}) do
    tasks = Enum.flat_map(epics, & &1.tasks)
    total = length(tasks)
    completed = Enum.count(tasks, &(&1.status == :completed))
    in_progress = Enum.count(tasks, &(&1.status == :in_progress))
    blocked = Enum.count(tasks, &(&1.status == :blocked))
    pending = total - completed - in_progress - blocked

    percent = if total > 0, do: Float.round(completed / total * 100.0, 1), else: 0.0

    %{
      total_tasks: total,
      completed: completed,
      in_progress: in_progress,
      blocked: blocked,
      pending: pending,
      percent: percent
    }
  end

  @doc "Compute progress for a specific epic."
  @spec epic_progress(epic()) :: map()
  def epic_progress(%{tasks: tasks}) do
    total = length(tasks)
    completed = Enum.count(tasks, &(&1.status == :completed))
    percent = if total > 0, do: Float.round(completed / total * 100.0, 1), else: 0.0

    %{total: total, completed: completed, percent: percent}
  end

  @doc "Convert project to a plain map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = project) do
    %{
      id: project.id,
      name: project.name,
      description: project.description,
      repo: project.repo,
      seed_issue_url: project.seed_issue_url,
      epics: project.epics,
      metadata: project.metadata,
      progress: progress(project),
      created_at: project.created_at,
      updated_at: project.updated_at
    }
  end

  # ── Private ─────────────────────────────────────────────────────

  defp save(%__MODULE__{id: id} = project) do
    MetadataStore.put(@namespace, id, Map.from_struct(project))
  end

  defp from_map(data) do
    %__MODULE__{
      id: data[:id] || data["id"],
      name: data[:name] || data["name"],
      description: data[:description] || data["description"],
      repo: data[:repo] || data["repo"],
      seed_issue_url: data[:seed_issue_url] || data["seed_issue_url"],
      epics: data[:epics] || data["epics"] || [],
      metadata: data[:metadata] || data["metadata"] || %{},
      created_at: data[:created_at] || data["created_at"],
      updated_at: data[:updated_at] || data["updated_at"]
    }
  end

  defp maybe_update(project, field, attrs) do
    case Map.get(attrs, field) || Map.get(attrs, to_string(field)) do
      nil -> project
      value -> Map.put(project, field, value)
    end
  end

  defp generate_id do
    "proj_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
