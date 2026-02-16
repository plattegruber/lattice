defmodule Lattice.Capabilities.GitHub.Stub do
  @moduledoc """
  Stub implementation of the GitHub capability.

  Returns canned responses for development and testing. Simulates a GitHub
  repository with issues that can be created, updated, labeled, and commented on.

  This stub uses an in-memory Agent to maintain state across calls within the
  same process lifetime. For tests that need isolation, use Mox instead.
  """

  @behaviour Lattice.Capabilities.GitHub

  @stub_issues [
    %{
      number: 1,
      title: "Set up CI pipeline",
      body: "Configure GitHub Actions for the project",
      state: "open",
      labels: ["enhancement"],
      comments: []
    },
    %{
      number: 2,
      title: "Sprite exceeded memory limit",
      body: "sprite-003 used more than 512MB during test run",
      state: "open",
      labels: ["incident", "needs-review"],
      comments: [
        %{id: 1, body: "Investigating memory usage patterns"}
      ]
    }
  ]

  @impl true
  def create_issue(title, attrs) do
    issue = %{
      number: System.unique_integer([:positive]),
      title: title,
      body: Map.get(attrs, :body, ""),
      state: "open",
      labels: Map.get(attrs, :labels, []),
      comments: []
    }

    {:ok, issue}
  end

  @impl true
  def update_issue(number, attrs) do
    case Enum.find(@stub_issues, &(&1.number == number)) do
      nil ->
        {:error, :not_found}

      issue ->
        {:ok, Map.merge(issue, attrs)}
    end
  end

  @impl true
  def add_label(number, label) do
    case Enum.find(@stub_issues, &(&1.number == number)) do
      nil ->
        {:error, :not_found}

      issue ->
        labels = Enum.uniq([label | issue.labels])
        {:ok, labels}
    end
  end

  @impl true
  def remove_label(number, label) do
    case Enum.find(@stub_issues, &(&1.number == number)) do
      nil ->
        {:error, :not_found}

      issue ->
        labels = List.delete(issue.labels, label)
        {:ok, labels}
    end
  end

  @impl true
  def create_comment(number, body) do
    case Enum.find(@stub_issues, &(&1.number == number)) do
      nil ->
        {:error, :not_found}

      _issue ->
        comment = %{
          id: System.unique_integer([:positive]),
          body: body,
          issue_number: number
        }

        {:ok, comment}
    end
  end

  @impl true
  def get_issue(number) do
    case Enum.find(@stub_issues, &(&1.number == number)) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  end

  @impl true
  def list_issues(opts) do
    issues =
      case Keyword.get(opts, :labels) do
        nil ->
          @stub_issues

        filter_labels ->
          Enum.filter(@stub_issues, fn issue ->
            Enum.any?(filter_labels, &(&1 in issue.labels))
          end)
      end

    {:ok, issues}
  end
end
