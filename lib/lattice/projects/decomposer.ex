defmodule Lattice.Projects.Decomposer do
  @moduledoc """
  Decomposes project descriptions or seed issues into structured
  epics and tasks.

  The decomposer analyzes a project's description and generates a
  proposed breakdown of work with dependency relationships.

  ## Heuristics

  The current implementation uses simple keyword-based heuristics to
  identify work items. Future versions will integrate with LLM for
  more sophisticated decomposition.
  """

  alias Lattice.Projects.Project

  @doc """
  Decompose a project description into epics and tasks.

  Returns a list of epic maps ready to be added to a project.
  """
  @spec decompose(String.t(), keyword()) :: [Project.epic()]
  def decompose(description, opts \\ []) do
    repo = Keyword.get(opts, :repo)

    description
    |> extract_sections()
    |> Enum.map(fn {title, items} ->
      tasks =
        items
        |> Enum.with_index()
        |> Enum.map(fn {item, idx} ->
          id = generate_task_id()

          %{
            id: id,
            description: item,
            intent_id: nil,
            status: :pending,
            blocks: [],
            blocked_by: if(idx > 0, do: [], else: [])
          }
        end)
        |> apply_sequential_dependencies()

      %{
        id: generate_epic_id(),
        title: title,
        description: "Epic: #{title}" <> if(repo, do: " (#{repo})", else: ""),
        tasks: tasks
      }
    end)
  end

  @doc """
  Detect if a GitHub issue looks like a project seed.

  Checks for markers like 'project' label, checklist items, or
  multi-section structure.
  """
  @spec seed_issue?(map()) :: boolean()
  def seed_issue?(issue) when is_map(issue) do
    labels = Map.get(issue, "labels", []) |> Enum.map(&label_name/1)
    body = Map.get(issue, "body", "") || ""

    has_project_label = "project" in labels || "epic" in labels
    has_checklist = String.contains?(body, "- [ ]")
    has_sections = length(String.split(body, ~r/^\#{2,3}\s/m)) > 2

    has_project_label || (has_checklist && has_sections)
  end

  @doc """
  Extract task items from a checklist-formatted body.
  """
  @spec extract_checklist(String.t()) :: [String.t()]
  def extract_checklist(body) when is_binary(body) do
    ~r/^-\s+\[[ x]\]\s+(.+)$/m
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.map(&String.trim/1)
  end

  # ── Private ─────────────────────────────────────────────────────

  defp extract_sections(description) do
    lines = String.split(description, "\n")

    {sections, current_title, current_items} =
      Enum.reduce(lines, {[], "General", []}, fn line, acc ->
        classify_line(line, acc)
      end)

    # Don't forget the last section
    finalize_section(sections, current_title, current_items)
  end

  defp classify_line(line, {sections, title, items}) do
    cond do
      String.match?(line, ~r/^\#{2,3}\s/) ->
        new_title = String.replace(line, ~r/^\#{2,3}\s+/, "") |> String.trim()
        {finalize_section(sections, title, items), new_title, []}

      String.match?(line, ~r/^-\s+\[[ x]\]\s/) ->
        item = Regex.replace(~r/^-\s+\[[ x]\]\s+/, line, "") |> String.trim()
        {sections, title, [item | items]}

      String.match?(line, ~r/^[-*]\s/) ->
        item = Regex.replace(~r/^[-*]\s+/, line, "") |> String.trim()
        {sections, title, [item | items]}

      true ->
        {sections, title, items}
    end
  end

  defp finalize_section(sections, _title, []), do: sections
  defp finalize_section(sections, title, items), do: sections ++ [{title, Enum.reverse(items)}]

  defp apply_sequential_dependencies(tasks) do
    task_ids = Enum.map(tasks, & &1.id)

    tasks
    |> Enum.with_index()
    |> Enum.map(fn {task, idx} ->
      blocked_by =
        if idx > 0, do: [Enum.at(task_ids, idx - 1)], else: []

      %{task | blocked_by: blocked_by}
    end)
  end

  defp label_name(label) when is_binary(label), do: label
  defp label_name(%{"name" => name}), do: name
  defp label_name(_), do: ""

  defp generate_task_id do
    "task_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp generate_epic_id do
    "epic_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
