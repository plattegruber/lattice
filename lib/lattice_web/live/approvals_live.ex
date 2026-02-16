defmodule LatticeWeb.ApprovalsLive do
  @moduledoc """
  Approvals queue LiveView — surfaces all items awaiting human approval.

  Displays GitHub issues that use the HITL label workflow (proposed, approved,
  in-progress, blocked, done). Items are grouped by sprite, filterable by label
  state and sprite ID, and sortable by recency or urgency.

  Subscribes to `sprites:approvals` PubSub topic on mount and updates the view
  whenever approval state changes arrive. Uses a periodic safety-net refresh
  (~30s) to catch any missed PubSub messages or external label changes.
  """

  use LatticeWeb, :live_view

  alias Lattice.Capabilities.GitHub
  alias Lattice.Capabilities.GitHub.Labels
  alias Lattice.Events
  alias Lattice.Events.ApprovalNeeded

  @refresh_interval_ms 30_000

  # Labels that represent pending/actionable states (not terminal)
  @pending_labels ["proposed", "approved", "in-progress", "blocked"]

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_approvals()
      Events.subscribe_fleet()
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Approvals")
     |> assign(:filter_label, "all")
     |> assign(:filter_sprite, "all")
     |> assign(:sort_by, "newest")
     |> assign_issues()}
  end

  # ── Event Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info(%ApprovalNeeded{}, socket) do
    {:noreply, assign_issues(socket)}
  end

  def handle_info({:fleet_summary, _summary}, socket) do
    {:noreply, socket}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_issues(socket)}
  end

  # Catch-all for other PubSub events
  def handle_info(_event, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_label", %{"label" => label}, socket) do
    {:noreply,
     socket
     |> assign(:filter_label, label)
     |> assign_derived()}
  end

  def handle_event("filter_sprite", %{"sprite" => sprite}, socket) do
    {:noreply,
     socket
     |> assign(:filter_sprite, sprite)
     |> assign_derived()}
  end

  def handle_event("sort", %{"sort_by" => sort_by}, socket) do
    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign_derived()}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Approvals Queue
        <:subtitle>
          Items awaiting human approval, linked to GitHub for action.
        </:subtitle>
      </.header>

      <.approval_summary
        total={length(@all_issues)}
        by_label={@by_label}
      />

      <.filters
        filter_label={@filter_label}
        filter_sprite={@filter_sprite}
        sort_by={@sort_by}
        sprite_ids={@sprite_ids}
      />

      <div :if={@filtered_issues == []} class="text-center py-12 text-base-content/60">
        <.icon name="hero-shield-check" class="size-12 mx-auto mb-4 text-success" />
        <p class="text-lg font-medium">No pending approvals</p>
        <p class="text-sm mt-1">All items have been processed or no matching items found.</p>
      </div>

      <div :if={@filtered_issues != []} class="space-y-6">
        <div
          :for={{group_key, group_issues} <- @grouped_issues}
          id={"group-#{group_key}"}
        >
          <h3 class="text-sm font-semibold text-base-content/70 mb-3 uppercase tracking-wide">
            {group_key}
            <span class="badge badge-sm badge-ghost ml-1">{length(group_issues)}</span>
          </h3>

          <div class="space-y-3">
            <div
              :for={issue <- group_issues}
              id={"approval-#{issue.number}"}
              class="card bg-base-200 shadow-sm"
            >
              <div class="card-body p-4">
                <div class="flex items-start justify-between gap-4">
                  <div class="flex items-center gap-3">
                    <.urgency_icon issue={issue} />
                    <div>
                      <div class="flex items-center gap-2 flex-wrap">
                        <span class="font-mono text-xs text-base-content/50">
                          #{issue.number}
                        </span>
                        <h3 class="font-medium text-sm">{issue.title}</h3>
                        <.label_badge label={hitl_label(issue)} />
                      </div>
                      <div class="flex items-center gap-3 mt-1 text-xs text-base-content/60">
                        <span :if={sprite_id = extract_sprite_id(issue)}>
                          <.icon name="hero-cpu-chip" class="size-3 inline" />
                          {sprite_id}
                        </span>
                        <span>
                          <.icon name="hero-clock" class="size-3 inline" /> Created
                          <.relative_time datetime={parse_time(issue.created_at)} />
                        </span>
                        <span :if={issue.created_at != issue.updated_at}>
                          Updated <.relative_time datetime={parse_time(issue.updated_at)} />
                        </span>
                      </div>
                      <p
                        :if={reason = extract_reason(issue)}
                        class="text-xs text-base-content/50 mt-1"
                      >
                        {reason}
                      </p>
                    </div>
                  </div>
                  <div class="text-right shrink-0 space-y-1">
                    <.staleness_badge issue={issue} />
                    <div>
                      <.link
                        href={github_issue_url(issue.number)}
                        target="_blank"
                        rel="noopener"
                        class="link link-primary text-xs"
                      >
                        View on GitHub
                        <.icon name="hero-arrow-top-right-on-square" class="size-3 inline ml-0.5" />
                      </.link>
                    </div>
                  </div>
                </div>

                <div :if={hitl_label(issue) == "proposed"} class="mt-3 bg-base-300 rounded-lg p-3">
                  <div class="text-xs font-medium text-base-content/60 mb-1">
                    Quick approve:
                  </div>
                  <code class="text-xs font-mono select-all">
                    gh issue edit {issue.number} --add-label approved --remove-label proposed
                  </code>
                </div>

                <div :if={hitl_label(issue) == "blocked"} class="mt-3 bg-base-300 rounded-lg p-3">
                  <div class="text-xs font-medium text-base-content/60 mb-1">
                    Unblock (return to proposed):
                  </div>
                  <code class="text-xs font-mono select-all">
                    gh issue edit {issue.number} --add-label proposed --remove-label blocked
                  </code>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Functional Components ──────────────────────────────────────────

  attr :total, :integer, required: true
  attr :by_label, :map, required: true

  defp approval_summary(assigns) do
    ~H"""
    <div class="stats shadow w-full">
      <div class="stat">
        <div class="stat-title">Total Items</div>
        <div class="stat-value">{@total}</div>
      </div>
      <div :for={label <- @by_label |> Map.keys() |> Enum.sort()} class="stat">
        <div class="stat-title">{format_label(label)}</div>
        <div class="stat-value text-lg">
          <.label_badge label={label} />
          <span class="ml-2">{Map.get(@by_label, label, 0)}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :filter_label, :string, required: true
  attr :filter_sprite, :string, required: true
  attr :sort_by, :string, required: true
  attr :sprite_ids, :list, required: true

  defp filters(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-3 items-end">
      <div class="form-control">
        <label class="label">
          <span class="label-text text-xs">Label State</span>
        </label>
        <select
          class="select select-bordered select-sm"
          phx-change="filter_label"
          name="label"
        >
          <option value="all" selected={@filter_label == "all"}>All labels</option>
          <option
            :for={label <- hitl_labels()}
            value={label}
            selected={@filter_label == label}
          >
            {format_label(label)}
          </option>
        </select>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text text-xs">Sprite</span>
        </label>
        <select
          class="select select-bordered select-sm"
          phx-change="filter_sprite"
          name="sprite"
        >
          <option value="all" selected={@filter_sprite == "all"}>All sprites</option>
          <option
            :for={sprite_id <- @sprite_ids}
            value={sprite_id}
            selected={@filter_sprite == sprite_id}
          >
            {sprite_id}
          </option>
        </select>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text text-xs">Sort</span>
        </label>
        <select
          class="select select-bordered select-sm"
          phx-change="sort"
          name="sort_by"
        >
          <option value="newest" selected={@sort_by == "newest"}>Newest first</option>
          <option value="oldest" selected={@sort_by == "oldest"}>Oldest first</option>
          <option value="urgent" selected={@sort_by == "urgent"}>Most urgent</option>
        </select>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true

  defp label_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", label_color(@label)]}>
      {@label}
    </span>
    """
  end

  attr :issue, :map, required: true

  defp urgency_icon(assigns) do
    label = hitl_label(assigns.issue)
    assigns = assign(assigns, :label, label)

    ~H"""
    <div :if={@label == "proposed"}>
      <.icon name="hero-hand-raised" class="size-6 text-warning" />
    </div>
    <div :if={@label == "approved"}>
      <.icon name="hero-check-circle" class="size-6 text-success" />
    </div>
    <div :if={@label == "in-progress"}>
      <.icon name="hero-arrow-path" class="size-6 text-info" />
    </div>
    <div :if={@label == "blocked"}>
      <.icon name="hero-no-symbol" class="size-6 text-error" />
    </div>
    <div :if={@label not in ["proposed", "approved", "in-progress", "blocked"]}>
      <.icon name="hero-question-mark-circle" class="size-6 text-base-content/40" />
    </div>
    """
  end

  attr :issue, :map, required: true

  defp staleness_badge(assigns) do
    created = parse_time(assigns.issue.created_at)
    age_hours = DateTime.diff(DateTime.utc_now(), created, :second) / 3600

    assigns = assign(assigns, :age_hours, age_hours)

    ~H"""
    <span :if={@age_hours > 24} class="badge badge-xs badge-error">
      stale
    </span>
    <span :if={@age_hours > 4 and @age_hours <= 24} class="badge badge-xs badge-warning">
      aging
    </span>
    """
  end

  attr :datetime, DateTime, required: true

  defp relative_time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@datetime)} title={DateTime.to_iso8601(@datetime)}>
      {format_relative(@datetime)}
    </time>
    """
  end

  # ── Data Loading & Filtering ────────────────────────────────────────

  defp assign_issues(socket) do
    all_issues = fetch_approval_issues()

    socket
    |> assign(:all_issues, all_issues)
    |> assign(:sprite_ids, extract_all_sprite_ids(all_issues))
    |> assign_derived()
  end

  defp assign_derived(socket) do
    all_issues = socket.assigns.all_issues
    filter_label = socket.assigns.filter_label
    filter_sprite = socket.assigns.filter_sprite
    sort_by = socket.assigns.sort_by

    filtered = apply_filters(all_issues, filter_label, filter_sprite)
    sorted = apply_sort(filtered, sort_by)
    grouped = group_by_sprite(sorted)
    by_label = count_by_label(all_issues)

    socket
    |> assign(:filtered_issues, sorted)
    |> assign(:grouped_issues, grouped)
    |> assign(:by_label, by_label)
    |> assign(:pending_count, count_pending(all_issues))
  end

  defp fetch_approval_issues do
    case GitHub.list_issues(labels: Labels.all()) do
      {:ok, issues} ->
        Enum.filter(issues, fn issue ->
          Enum.any?(issue.labels, &Labels.valid?/1)
        end)

      {:error, _reason} ->
        []
    end
  end

  defp apply_filters(issues, label_filter, sprite_filter) do
    issues
    |> filter_by_label(label_filter)
    |> filter_by_sprite(sprite_filter)
  end

  defp filter_by_label(issues, "all"), do: issues

  defp filter_by_label(issues, label) do
    Enum.filter(issues, fn issue -> label in issue.labels end)
  end

  defp filter_by_sprite(issues, "all"), do: issues

  defp filter_by_sprite(issues, sprite_id) do
    Enum.filter(issues, fn issue ->
      extract_sprite_id(issue) == sprite_id
    end)
  end

  defp apply_sort(issues, "newest") do
    Enum.sort_by(issues, &parse_time(&1.created_at), {:desc, DateTime})
  end

  defp apply_sort(issues, "oldest") do
    Enum.sort_by(issues, &parse_time(&1.created_at), {:asc, DateTime})
  end

  defp apply_sort(issues, "urgent") do
    Enum.sort_by(
      issues,
      fn issue -> {urgency_order(hitl_label(issue)), parse_time(issue.created_at)} end,
      fn {urg_a, ts_a}, {urg_b, ts_b} ->
        if urg_a == urg_b do
          DateTime.compare(ts_a, ts_b) == :lt
        else
          urg_a < urg_b
        end
      end
    )
  end

  defp apply_sort(issues, _), do: issues

  defp group_by_sprite(issues) do
    issues
    |> Enum.group_by(fn issue ->
      extract_sprite_id(issue) || "unassigned"
    end)
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  defp count_by_label(issues) do
    issues
    |> Enum.flat_map(fn issue ->
      Enum.filter(issue.labels, &Labels.valid?/1)
    end)
    |> Enum.frequencies()
  end

  defp count_pending(issues) do
    Enum.count(issues, fn issue ->
      Enum.any?(issue.labels, fn label -> label in @pending_labels end)
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp hitl_labels, do: Labels.all()

  defp hitl_label(issue) do
    Enum.find(issue.labels, "unknown", &Labels.valid?/1)
  end

  defp extract_sprite_id(issue) do
    case Regex.run(~r/\*\*Sprite:\*\*\s*`([^`]+)`/, issue.body || "") do
      [_, sprite_id] -> sprite_id
      _ -> nil
    end
  end

  defp extract_reason(issue) do
    case Regex.run(~r/\*\*Reason:\*\*\s*(.+)/, issue.body || "") do
      [_, reason] -> String.trim(reason)
      _ -> nil
    end
  end

  defp extract_all_sprite_ids(issues) do
    issues
    |> Enum.map(&extract_sprite_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_time(nil), do: DateTime.utc_now()

  defp parse_time(time_string) when is_binary(time_string) do
    case DateTime.from_iso8601(time_string) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp parse_time(%DateTime{} = dt), do: dt
  defp parse_time(_), do: DateTime.utc_now()

  defp github_issue_url(issue_number) do
    repo = Lattice.Instance.resource(:github_repo)

    if repo do
      "https://github.com/#{repo}/issues/#{issue_number}"
    else
      "#issue-#{issue_number}"
    end
  end

  defp label_color("proposed"), do: "badge-warning"
  defp label_color("approved"), do: "badge-success"
  defp label_color("in-progress"), do: "badge-info"
  defp label_color("blocked"), do: "badge-error"
  defp label_color("done"), do: "badge-ghost"
  defp label_color(_), do: "badge-ghost"

  defp urgency_order("blocked"), do: 0
  defp urgency_order("proposed"), do: 1
  defp urgency_order("approved"), do: 2
  defp urgency_order("in-progress"), do: 3
  defp urgency_order("done"), do: 4
  defp urgency_order(_), do: 5

  defp format_label(label) do
    label
    |> String.replace("-", " ")
    |> String.capitalize()
  end

  defp format_relative(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
