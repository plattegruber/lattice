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
      comments: [],
      created_at: "2026-02-15T10:00:00Z",
      updated_at: "2026-02-15T10:00:00Z"
    },
    %{
      number: 2,
      title: "Sprite exceeded memory limit",
      body: "sprite-003 used more than 512MB during test run",
      state: "open",
      labels: ["incident", "needs-review"],
      comments: [
        %{id: 1, body: "Investigating memory usage patterns"}
      ],
      created_at: "2026-02-15T12:00:00Z",
      updated_at: "2026-02-15T14:00:00Z"
    },
    %{
      number: 10,
      title: "[Sprite] Deploy feature-auth branch to staging",
      body:
        "## Proposed Action\n\n**Action:** Deploy feature-auth branch to staging\n" <>
          "**Sprite:** `sprite-001`\n**Reason:** New auth feature ready for testing\n",
      state: "open",
      labels: ["proposed"],
      comments: [],
      created_at: "2026-02-16T08:00:00Z",
      updated_at: "2026-02-16T08:00:00Z"
    },
    %{
      number: 11,
      title: "[Sprite] Run database migration on staging",
      body:
        "## Proposed Action\n\n**Action:** Run database migration on staging\n" <>
          "**Sprite:** `sprite-002`\n**Reason:** Schema update required for new feature\n",
      state: "open",
      labels: ["proposed"],
      comments: [],
      created_at: "2026-02-16T06:00:00Z",
      updated_at: "2026-02-16T06:00:00Z"
    },
    %{
      number: 12,
      title: "[Sprite] Scale worker pool to 8 instances",
      body:
        "## Proposed Action\n\n**Action:** Scale worker pool to 8 instances\n" <>
          "**Sprite:** `sprite-001`\n**Reason:** Increased traffic requires more capacity\n",
      state: "open",
      labels: ["approved"],
      comments: [%{id: 2, body: "Approved -- go ahead with the scale-up."}],
      created_at: "2026-02-15T22:00:00Z",
      updated_at: "2026-02-16T09:00:00Z"
    },
    %{
      number: 13,
      title: "[Sprite] Delete stale preview environments",
      body:
        "## Proposed Action\n\n**Action:** Delete stale preview environments\n" <>
          "**Sprite:** `sprite-003`\n**Reason:** Clean up unused resources\n",
      state: "open",
      labels: ["in-progress"],
      comments: [],
      created_at: "2026-02-15T18:00:00Z",
      updated_at: "2026-02-16T07:00:00Z"
    },
    %{
      number: 14,
      title: "[Sprite] Rotate API keys for production",
      body:
        "## Proposed Action\n\n**Action:** Rotate API keys for production\n" <>
          "**Sprite:** `sprite-002`\n**Reason:** Scheduled key rotation\n",
      state: "open",
      labels: ["blocked"],
      comments: [%{id: 3, body: "Blocked: waiting for maintenance window confirmation."}],
      created_at: "2026-02-14T16:00:00Z",
      updated_at: "2026-02-15T20:00:00Z"
    }
  ]

  @impl true
  def create_issue(title, attrs) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    issue = %{
      number: System.unique_integer([:positive]),
      title: title,
      body: Map.get(attrs, :body, ""),
      state: "open",
      labels: Map.get(attrs, :labels, []),
      comments: [],
      created_at: now,
      updated_at: now
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
