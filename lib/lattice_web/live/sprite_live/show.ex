defmodule LatticeWeb.SpriteLive.Show do
  @moduledoc """
  Sprite detail LiveView -- real-time view of a single Sprite's state.

  Displays:

  - **Status panel** -- current API status (cold/warm/running)
  - **Event timeline** -- last N events streamed via PubSub
  - **Observation & backoff info** -- failure count, backoff duration
  - **Tasks section** -- active/recent tasks for this sprite with links to
    intent detail view
  - **Assign Task form** -- quick action to assign a task to this sprite
  - **Approval queue** -- placeholder for future HITL approval workflow

  Subscribes to `sprites:<sprite_id>` and `intents` PubSub topics on mount
  and renders projections of the event stream. No polling.
  """

  use LatticeWeb, :live_view

  alias Lattice.Events
  alias Lattice.Events.ApprovalNeeded
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store, as: IntentStore
  alias Lattice.Protocol.Event
  alias Lattice.Protocol.SkillDiscovery
  alias Lattice.Sprites.ExecSession
  alias Lattice.Sprites.ExecSupervisor
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Logs
  alias Lattice.Sprites.Sprite
  alias Lattice.Sprites.State

  @max_events 50
  @refresh_interval_ms 30_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(%{"id" => sprite_id}, _session, socket) do
    case fetch_sprite_state(sprite_id) do
      {:ok, sprite_state} ->
        historical =
          if connected?(socket) do
            Events.subscribe_sprite(sprite_id)
            Events.subscribe_fleet()
            Events.subscribe_intents()
            Events.subscribe_runs()
            Events.subscribe_sprite_logs(sprite_id)
            schedule_refresh()
            Logs.fetch_historical(sprite_id)
          else
            []
          end

        {:ok,
         socket
         |> assign(:page_title, State.display_name(sprite_state))
         |> assign(:sprite_id, sprite_id)
         |> assign(:sprite_state, sprite_state)
         |> assign(:events, [])
         |> assign(:last_reconciliation, nil)
         |> assign(:not_found, false)
         |> assign(:show_task_form, false)
         |> assign(:task_form, default_task_form())
         |> assign(:exec_sessions, load_exec_sessions(sprite_id))
         |> assign(:active_session_id, nil)
         |> assign(:exec_command, "")
         |> assign(:log_pinned_to_bottom, true)
         |> assign(:has_sprite_logs, historical != [])
         |> assign(:current_progress, nil)
         |> assign(:protocol_events, [])
         |> assign(:skills, [])
         |> assign(:skills_expanded, false)
         |> stream(:sprite_logs, historical)
         |> stream(:log_lines, [])
         |> assign_sprite_tasks()
         |> then(fn socket ->
           if connected?(socket), do: maybe_discover_skills(socket), else: socket
         end)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> assign(:page_title, "Sprite Not Found")
         |> assign(:sprite_id, sprite_id)
         |> assign(:sprite_state, nil)
         |> assign(:events, [])
         |> assign(:last_reconciliation, nil)
         |> assign(:not_found, true)
         |> assign(:show_task_form, false)
         |> assign(:task_form, default_task_form())
         |> assign(:exec_sessions, [])
         |> assign(:active_session_id, nil)
         |> assign(:exec_command, "")
         |> assign(:log_pinned_to_bottom, true)
         |> assign(:has_sprite_logs, false)
         |> assign(:current_progress, nil)
         |> assign(:protocol_events, [])
         |> assign(:skills, [])
         |> assign(:skills_expanded, false)
         |> stream(:sprite_logs, [])
         |> stream(:log_lines, [])
         |> assign(:sprite_tasks, [])}
    end
  end

  # ── Event Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info(%StateChange{} = event, socket) do
    socket =
      socket
      |> refresh_sprite_state()
      |> prepend_event(event)

    {:noreply, socket}
  end

  def handle_info(%ReconciliationResult{} = event, socket) do
    socket =
      socket
      |> refresh_sprite_state()
      |> prepend_event(event)
      |> assign(:last_reconciliation, event)

    {:noreply, socket}
  end

  def handle_info(%ApprovalNeeded{} = event, socket) do
    socket =
      socket
      |> refresh_sprite_state()
      |> prepend_event(event)

    {:noreply, socket}
  end

  def handle_info({:fleet_summary, _summary}, socket) do
    {:noreply, refresh_sprite_state(socket)}
  end

  # Intent store events -- refresh tasks when intents change
  def handle_info({:intent_created, _intent}, socket) do
    {:noreply, assign_sprite_tasks(socket)}
  end

  def handle_info({:intent_transitioned, _intent}, socket) do
    {:noreply, assign_sprite_tasks(socket)}
  end

  def handle_info({:intent_artifact_added, _intent, _artifact}, socket) do
    {:noreply, assign_sprite_tasks(socket)}
  end

  def handle_info({:run_artifact_added, _run, _artifact}, socket) do
    {:noreply, assign_sprite_tasks(socket)}
  end

  def handle_info({:run_assumption_added, _run}, socket) do
    {:noreply, assign_sprite_tasks(socket)}
  end

  def handle_info({:run_blocked, _run}, socket) do
    {:noreply, assign_sprite_tasks(socket)}
  end

  def handle_info({:run_resumed, _run}, socket) do
    {:noreply, assign_sprite_tasks(socket)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()

    {:noreply,
     socket
     |> refresh_sprite_state()
     |> assign_sprite_tasks()
     |> assign(:exec_sessions, load_exec_sessions(socket.assigns.sprite_id))}
  end

  # Exec session output via PubSub
  def handle_info({:exec_output, %{session_id: sid, stream: stream, chunk: chunk}}, socket) do
    socket =
      if socket.assigns[:active_session_id] == sid do
        line = %{
          id: System.unique_integer([:positive]),
          stream: stream,
          data: chunk,
          timestamp: DateTime.utc_now()
        }

        stream_insert(socket, :log_lines, line)
      else
        socket
      end

    # Refresh session list when a session exits so status badges update
    socket =
      if stream == :exit do
        assign(socket, :exec_sessions, load_exec_sessions(socket.assigns.sprite_id))
      else
        socket
      end

    {:noreply, socket}
  end

  # Exec session process died — refresh session list
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, assign(socket, :exec_sessions, load_exec_sessions(socket.assigns.sprite_id))}
  end

  # Sprite log stream events
  def handle_info({:sprite_log, log_line}, socket) do
    {:noreply,
     socket
     |> assign(:has_sprite_logs, true)
     |> stream_insert(:sprite_logs, log_line, limit: -500)}
  end

  # Protocol events from exec sessions (progress, warning, checkpoint)
  def handle_info(
        {:protocol_event, %Event{type: "progress", data: data}},
        socket
      ) do
    progress = %{
      message: data.message,
      percent: data.percent,
      phase: data.phase,
      timestamp: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:current_progress, progress)
     |> prepend_protocol_event("progress", data.message)}
  end

  def handle_info(
        {:protocol_event, %Event{type: "warning", data: data}},
        socket
      ) do
    {:noreply, prepend_protocol_event(socket, "warning", data.message)}
  end

  def handle_info(
        {:protocol_event, %Event{type: "checkpoint", data: data}},
        socket
      ) do
    {:noreply, prepend_protocol_event(socket, "checkpoint", data.message)}
  end

  def handle_info({:protocol_event, %Event{}}, socket) do
    {:noreply, socket}
  end

  # Catch-all for unexpected PubSub messages
  def handle_info(_event, socket) do
    {:noreply, refresh_sprite_state(socket)}
  end

  @impl true
  def handle_event("show_task_form", _params, socket) do
    {:noreply, assign(socket, :show_task_form, true)}
  end

  def handle_event("hide_task_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_task_form, false)
     |> assign(:task_form, default_task_form())}
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    {:noreply, assign(socket, :task_form, params)}
  end

  def handle_event("validate_exec_command", %{"command" => command}, socket) do
    {:noreply, assign(socket, :exec_command, command)}
  end

  def handle_event("start_exec", %{"command" => command}, socket) do
    sprite_id = socket.assigns.sprite_id

    case ExecSupervisor.start_session(sprite_id: sprite_id, command: command) do
      {:ok, session_pid} ->
        {:ok, state} = ExecSession.get_state(session_pid)
        Process.monitor(session_pid)

        Phoenix.PubSub.subscribe(
          Lattice.PubSub,
          ExecSession.exec_topic(state.session_id)
        )

        Events.subscribe_exec_events(state.session_id)

        {:noreply,
         socket
         |> assign(:exec_sessions, load_exec_sessions(sprite_id))
         |> assign(:active_session_id, state.session_id)
         |> assign(:exec_command, "")
         |> assign(:current_progress, nil)
         |> stream(:log_lines, [], reset: true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start session: #{inspect(reason)}")}
    end
  end

  def handle_event("view_session", %{"session-id" => session_id}, socket) do
    # Unsubscribe from old session if any
    if old_sid = socket.assigns[:active_session_id] do
      Phoenix.PubSub.unsubscribe(Lattice.PubSub, ExecSession.exec_topic(old_sid))
      Phoenix.PubSub.unsubscribe(Lattice.PubSub, Events.exec_events_topic(old_sid))
    end

    # Subscribe to new session (output + protocol events)
    Phoenix.PubSub.subscribe(Lattice.PubSub, ExecSession.exec_topic(session_id))
    Events.subscribe_exec_events(session_id)

    log_lines = load_session_output(session_id)

    {:noreply,
     socket
     |> assign(:active_session_id, session_id)
     |> assign(:current_progress, nil)
     |> stream(:log_lines, log_lines, reset: true)}
  end

  def handle_event("close_session", %{"session-id" => session_id}, socket) do
    case ExecSupervisor.get_session_pid(session_id) do
      {:ok, pid} -> ExecSession.close(pid)
      _ -> :ok
    end

    Phoenix.PubSub.unsubscribe(Lattice.PubSub, ExecSession.exec_topic(session_id))
    Phoenix.PubSub.unsubscribe(Lattice.PubSub, Events.exec_events_topic(session_id))

    new_active =
      if socket.assigns[:active_session_id] == session_id,
        do: nil,
        else: socket.assigns[:active_session_id]

    {:noreply,
     socket
     |> assign(:exec_sessions, load_exec_sessions(socket.assigns.sprite_id))
     |> assign(:active_session_id, new_active)
     |> assign(:current_progress, nil)
     |> stream(:log_lines, [], reset: true)}
  end

  def handle_event("detach_session", _params, socket) do
    if sid = socket.assigns[:active_session_id] do
      Phoenix.PubSub.unsubscribe(Lattice.PubSub, ExecSession.exec_topic(sid))
      Phoenix.PubSub.unsubscribe(Lattice.PubSub, Events.exec_events_topic(sid))
    end

    {:noreply,
     socket
     |> assign(:active_session_id, nil)
     |> assign(:current_progress, nil)
     |> stream(:log_lines, [], reset: true)}
  end

  def handle_event("toggle_skills", _params, socket) do
    {:noreply, assign(socket, :skills_expanded, !socket.assigns.skills_expanded)}
  end

  def handle_event("toggle_pin_to_bottom", _params, socket) do
    {:noreply, assign(socket, :log_pinned_to_bottom, !socket.assigns.log_pinned_to_bottom)}
  end

  def handle_event("submit_task", %{"task" => params}, socket) do
    sprite_name = socket.assigns.sprite_id

    case create_and_propose_task(sprite_name, params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Task assigned. Intent: #{truncate_id(result.id)}")
         |> assign(:show_task_form, false)
         |> assign(:task_form, default_task_form())
         |> assign_sprite_tasks()}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.breadcrumb sprite_id={@sprite_id} sprite_state={@sprite_state} />

      <div :if={@not_found} class="text-center py-12">
        <.icon name="hero-exclamation-triangle" class="size-12 mx-auto mb-4 text-warning" />
        <p class="text-lg font-medium">Sprite not found</p>
        <p class="text-sm text-base-content/60 mt-1">
          No Sprite process with ID "{@sprite_id}" is currently running.
        </p>
        <div class="mt-6">
          <.link navigate={~p"/sprites"} class="btn btn-ghost">
            <.icon name="hero-arrow-left" class="size-4 mr-1" /> Back to Fleet
          </.link>
        </div>
      </div>

      <div :if={!@not_found} class="space-y-6">
        <.header>
          {State.display_name(@sprite_state)}
          <:subtitle>
            <span :if={@sprite_state.name}>ID: {@sprite_id} &middot;</span>
            Real-time detail view for this Sprite process.
          </:subtitle>
        </.header>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.status_panel sprite_state={@sprite_state} />
          <.observation_panel
            sprite_state={@sprite_state}
            last_reconciliation={@last_reconciliation}
          />
        </div>

        <.progress_status_bar :if={@current_progress} progress={@current_progress} />

        <.tags_panel tags={@sprite_state.tags} />

        <.skills_panel
          skills={@skills}
          expanded={@skills_expanded}
        />

        <.sprite_log_panel
          sprite_logs={@streams.sprite_logs}
          pinned_to_bottom={@log_pinned_to_bottom}
          has_sprite_logs={@has_sprite_logs}
        />

        <.tasks_section
          sprite_id={@sprite_id}
          tasks={@sprite_tasks}
          show_task_form={@show_task_form}
          task_form={@task_form}
        />

        <.event_timeline events={@events} />

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.exec_sessions_panel
            exec_sessions={@exec_sessions}
            active_session_id={@active_session_id}
            exec_command={@exec_command}
            log_lines={@streams.log_lines}
          />
          <.approval_queue_placeholder />
        </div>
      </div>
    </div>
    """
  end

  # ── Functional Components ──────────────────────────────────────────

  attr :sprite_id, :string, required: true
  attr :sprite_state, State, default: nil

  defp breadcrumb(assigns) do
    ~H"""
    <div class="text-sm breadcrumbs">
      <ul>
        <li>
          <.link navigate={~p"/sprites"} class="link link-hover">
            <.icon name="hero-squares-2x2" class="size-4 mr-1" /> Fleet
          </.link>
        </li>
        <li>
          <span class="font-medium">
            {if @sprite_state, do: State.display_name(@sprite_state), else: @sprite_id}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr :sprite_state, State, required: true

  defp status_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-signal" class="size-5" /> Status
        </h2>

        <div class="mt-2">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
            Current Status
          </div>
          <div class="mt-1">
            <.state_badge state={@sprite_state.status} />
          </div>
        </div>

        <div class="text-xs text-base-content/50 mt-4">
          Last updated: <.relative_time datetime={@sprite_state.updated_at} />
        </div>
      </div>
    </div>
    """
  end

  attr :sprite_state, State, required: true
  attr :last_reconciliation, ReconciliationResult, default: nil

  defp observation_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-eye" class="size-5" /> Observation
        </h2>

        <div class="grid grid-cols-2 gap-4 mt-2">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Failures
            </div>
            <div class="mt-1">
              <span class={[
                "badge badge-sm",
                failure_color(@sprite_state.failure_count)
              ]}>
                {@sprite_state.failure_count}
              </span>
            </div>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Backoff
            </div>
            <div class="mt-1 text-sm font-mono">
              {format_duration(@sprite_state.backoff_ms)}
            </div>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4 mt-4">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Max Backoff
            </div>
            <div class="mt-1 text-sm font-mono">
              {format_duration(@sprite_state.max_backoff_ms)}
            </div>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Last Observed
            </div>
            <div class="mt-1 text-sm">
              <span :if={@sprite_state.last_observed_at}>
                <.relative_time datetime={@sprite_state.last_observed_at} />
              </span>
              <span :if={!@sprite_state.last_observed_at} class="text-base-content/40">never</span>
            </div>
          </div>
        </div>

        <div :if={@last_reconciliation} class="divider my-2"></div>
        <div :if={@last_reconciliation} class="text-sm">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
            Last Observation Cycle
          </div>
          <div class="flex items-center gap-2">
            <.outcome_badge outcome={@last_reconciliation.outcome} />
            <span class="text-base-content/60 text-xs">
              {format_duration(@last_reconciliation.duration_ms)}
            </span>
          </div>
          <p :if={@last_reconciliation.details} class="text-xs text-base-content/50 mt-1">
            {@last_reconciliation.details}
          </p>
        </div>

        <div class="text-xs text-base-content/50 mt-2">
          Started: <.relative_time datetime={@sprite_state.started_at} />
        </div>
      </div>
    </div>
    """
  end

  attr :sprite_id, :string, required: true
  attr :tasks, :list, required: true
  attr :show_task_form, :boolean, required: true
  attr :task_form, :map, required: true

  defp tasks_section(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h2 class="card-title text-base">
            <.icon name="hero-command-line" class="size-5" /> Tasks
          </h2>
          <button
            :if={!@show_task_form}
            phx-click="show_task_form"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="size-4" /> Assign Task
          </button>
        </div>

        <.assign_task_form
          :if={@show_task_form}
          sprite_id={@sprite_id}
          task_form={@task_form}
        />

        <div :if={@tasks == [] and !@show_task_form} class="text-center py-6 text-base-content/50">
          <.icon name="hero-inbox" class="size-8 mx-auto mb-2" />
          <p class="text-sm">No tasks for this sprite yet.</p>
        </div>

        <div :if={@tasks != []} class="overflow-x-auto mt-4">
          <table class="table table-xs table-zebra">
            <thead>
              <tr>
                <th>Task</th>
                <th>Kind</th>
                <th>State</th>
                <th>Repo</th>
                <th>Updated</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={task <- @tasks} id={"task-#{task.id}"}>
                <td class="font-mono text-xs">{truncate_id(task.id)}</td>
                <td>
                  <span class="badge badge-xs badge-outline">
                    {Map.get(task.payload, "task_kind", "-")}
                  </span>
                </td>
                <td>
                  <.task_state_badge state={task.state} />
                </td>
                <td class="text-xs font-mono">
                  {Map.get(task.payload, "repo", "-")}
                </td>
                <td class="text-xs">
                  <.relative_time datetime={task.updated_at} />
                </td>
                <td>
                  <.link
                    navigate={~p"/intents/#{task.id}"}
                    class="link link-primary text-xs"
                  >
                    View
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :sprite_id, :string, required: true
  attr :task_form, :map, required: true

  defp assign_task_form(assigns) do
    ~H"""
    <form phx-submit="submit_task" phx-change="validate_task" class="mt-4 space-y-4">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text">Sprite</span>
          </label>
          <input
            type="text"
            value={@sprite_id}
            class="input input-bordered input-sm"
            disabled
          />
        </div>
        <div class="form-control">
          <label class="label">
            <span class="label-text">Repository *</span>
          </label>
          <input
            type="text"
            name="task[repo]"
            value={Map.get(@task_form, "repo", "")}
            placeholder="owner/repo"
            class="input input-bordered input-sm"
            required
          />
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text">Task Kind *</span>
          </label>
          <select name="task[task_kind]" class="select select-bordered select-sm" required>
            <option value="" disabled selected={Map.get(@task_form, "task_kind", "") == ""}>
              Select a task kind
            </option>
            <option
              value="open_pr_trivial_change"
              selected={Map.get(@task_form, "task_kind") == "open_pr_trivial_change"}
            >
              Open PR (Trivial Change)
            </option>
            <option
              value="open_pr"
              selected={Map.get(@task_form, "task_kind") == "open_pr"}
            >
              Open PR
            </option>
            <option
              value="investigate"
              selected={Map.get(@task_form, "task_kind") == "investigate"}
            >
              Investigate
            </option>
            <option
              value="refactor"
              selected={Map.get(@task_form, "task_kind") == "refactor"}
            >
              Refactor
            </option>
          </select>
        </div>
        <div class="form-control">
          <label class="label">
            <span class="label-text">Base Branch</span>
          </label>
          <input
            type="text"
            name="task[base_branch]"
            value={Map.get(@task_form, "base_branch", "")}
            placeholder="main"
            class="input input-bordered input-sm"
          />
        </div>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text">PR Title</span>
        </label>
        <input
          type="text"
          name="task[pr_title]"
          value={Map.get(@task_form, "pr_title", "")}
          placeholder="Optional PR title"
          class="input input-bordered input-sm"
        />
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text">Instructions *</span>
        </label>
        <textarea
          name="task[instructions]"
          rows="3"
          placeholder="What should this sprite do?"
          class="textarea textarea-bordered"
          required
        >{Map.get(@task_form, "instructions", "")}</textarea>
      </div>

      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm">
          <.icon name="hero-paper-airplane" class="size-4" /> Assign Task
        </button>
        <button type="button" phx-click="hide_task_form" class="btn btn-ghost btn-sm">
          Cancel
        </button>
      </div>
    </form>
    """
  end

  attr :tags, :map, required: true

  defp tags_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-tag" class="size-5" /> Tags
        </h2>

        <div :if={@tags == nil or @tags == %{}} class="text-center py-6 text-base-content/50">
          <.icon name="hero-tag" class="size-8 mx-auto mb-2" />
          <p class="text-sm">No tags assigned to this sprite.</p>
        </div>

        <div :if={@tags != nil and @tags != %{}} class="overflow-x-auto">
          <table class="table table-xs table-zebra">
            <thead>
              <tr>
                <th>Key</th>
                <th>Value</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{key, value} <- @tags}>
                <td class="font-mono text-xs">{key}</td>
                <td class="text-xs">{value}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :skills, :list, required: true
  attr :expanded, :boolean, default: false

  defp skills_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h2 class="card-title text-base">
            <.icon name="hero-puzzle-piece" class="size-5" /> Skills
            <span :if={@skills != []} class="badge badge-sm badge-ghost">
              {length(@skills)}
            </span>
          </h2>
          <button
            :if={@skills != []}
            phx-click="toggle_skills"
            class="btn btn-ghost btn-xs"
          >
            {if @expanded, do: "Collapse", else: "Expand"}
          </button>
        </div>

        <div :if={@skills == []} class="text-center py-4 text-base-content/50">
          <.icon name="hero-puzzle-piece" class="size-8 mx-auto mb-2" />
          <p class="text-sm">No skills discovered for this sprite.</p>
        </div>

        <div :if={@skills != [] and @expanded} class="overflow-x-auto mt-2">
          <table class="table table-xs table-zebra">
            <thead>
              <tr>
                <th>Name</th>
                <th>Description</th>
                <th>Inputs</th>
                <th>Outputs</th>
                <th>Events</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={skill <- @skills} id={"skill-#{skill.name}"}>
                <td class="font-mono text-xs font-medium">{skill.name}</td>
                <td class="text-xs">{skill.description || "-"}</td>
                <td class="text-xs">{length(skill.inputs)}</td>
                <td class="text-xs">{length(skill.outputs)}</td>
                <td>
                  <span :if={skill.produces_events} class="badge badge-xs badge-success">yes</span>
                  <span :if={!skill.produces_events} class="badge badge-xs badge-ghost">no</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@skills != [] and !@expanded} class="flex flex-wrap gap-2 mt-2">
          <span :for={skill <- @skills} class="badge badge-sm badge-outline">
            {skill.name}
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :sprite_logs, :list, required: true
  attr :pinned_to_bottom, :boolean, default: true
  attr :has_sprite_logs, :boolean, default: false

  defp sprite_log_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h2 class="card-title text-base">
            <.icon name="hero-document-text" class="size-5" /> Sprite Logs
            <span class="loading loading-spinner loading-xs ml-2 text-success"></span>
          </h2>
          <label class="label cursor-pointer gap-2">
            <span class="label-text text-xs">Auto-scroll</span>
            <input
              type="checkbox"
              class="toggle toggle-xs toggle-success"
              checked={@pinned_to_bottom}
              phx-click="toggle_pin_to_bottom"
            />
          </label>
        </div>

        <div
          id="sprite-logs-container"
          phx-update="stream"
          phx-hook="LogViewer"
          data-pinned={to_string(@pinned_to_bottom)}
          class="bg-base-300 rounded-lg p-3 mt-2 max-h-96 overflow-y-auto font-mono text-xs"
        >
          <div
            :for={{dom_id, line} <- @sprite_logs}
            id={dom_id}
            class={["flex gap-2", log_level_class(line.level)]}
          >
            <span class="text-base-content/40 select-none shrink-0 tabular-nums">
              {format_log_timestamp(line.timestamp)}
            </span>
            <span class={["shrink-0 w-14 text-right", log_source_class(line.source)]}>
              [{format_log_source(line.source)}]
            </span>
            <span class="whitespace-pre-wrap break-all">{line.message}</span>
          </div>
        </div>

        <div :if={!@has_sprite_logs} class="text-center py-6 text-base-content/50">
          <.icon name="hero-inbox" class="size-8 mx-auto mb-2" />
          <p class="text-sm">No log output yet. Logs will appear here in real time.</p>
        </div>
      </div>
    </div>
    """
  end

  attr :events, :list, required: true

  defp event_timeline(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-clock" class="size-5" /> Event Timeline
        </h2>

        <div :if={@events == []} class="text-center py-6 text-base-content/50">
          <.icon name="hero-inbox" class="size-8 mx-auto mb-2" />
          <p class="text-sm">No events yet. Events will appear here in real time.</p>
        </div>

        <div :if={@events != []} class="overflow-x-auto max-h-80 overflow-y-auto">
          <table class="table table-xs table-zebra">
            <thead class="sticky top-0 bg-base-200">
              <tr>
                <th>Time</th>
                <th>Type</th>
                <th>Details</th>
              </tr>
            </thead>
            <tbody id="event-timeline">
              <tr :for={event <- @events} id={"event-#{event_id(event)}"}>
                <td class="whitespace-nowrap font-mono text-xs">
                  <.relative_time datetime={event.timestamp} />
                </td>
                <td>
                  <.event_type_badge event={event} />
                </td>
                <td class="text-xs">
                  <.event_details event={event} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :exec_sessions, :list, required: true
  attr :active_session_id, :string, default: nil
  attr :exec_command, :string, default: ""
  attr :log_lines, :list, required: true

  defp exec_sessions_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-command-line" class="size-5" /> Exec Sessions
        </h2>

        <form phx-submit="start_exec" phx-change="validate_exec_command" class="flex gap-2 mt-2">
          <input
            type="text"
            name="command"
            value={@exec_command}
            placeholder="Enter command..."
            class="input input-bordered input-sm flex-1"
            required
          />
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-play" class="size-4" /> Run
          </button>
        </form>

        <div :if={@exec_sessions == []} class="text-center py-4 text-base-content/50">
          <p class="text-sm">No active exec sessions.</p>
        </div>

        <div :if={@exec_sessions != []} class="overflow-x-auto mt-2">
          <table class="table table-xs table-zebra">
            <thead>
              <tr>
                <th>Session</th>
                <th>Command</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={session <- @exec_sessions} id={"session-#{session.session_id}"}>
                <td class="font-mono text-xs">{String.slice(session.session_id, 0, 16)}</td>
                <td class="text-xs font-mono">{session.command}</td>
                <td>
                  <span class={["badge badge-xs", exec_status_color(session.status)]}>
                    {session.status}
                  </span>
                </td>
                <td class="flex gap-1">
                  <button
                    phx-click="view_session"
                    phx-value-session-id={session.session_id}
                    class={[
                      "btn btn-xs",
                      if(@active_session_id == session.session_id,
                        do: "btn-primary",
                        else: "btn-ghost"
                      )
                    ]}
                  >
                    View
                  </button>
                  <button
                    phx-click="close_session"
                    phx-value-session-id={session.session_id}
                    class="btn btn-xs btn-ghost text-error"
                  >
                    Close
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@active_session_id} class="mt-4">
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs font-medium text-base-content/60">
              Viewing: {String.slice(@active_session_id, 0, 16)}
            </span>
            <button phx-click="detach_session" class="btn btn-xs btn-ghost">
              Detach
            </button>
          </div>
          <div
            id="exec-output"
            phx-update="stream"
            class="bg-base-300 rounded p-2 font-mono text-xs max-h-60 overflow-y-auto"
          >
            <div :for={{dom_id, line} <- @log_lines} id={dom_id} class={exec_line_class(line.stream)}>
              {line.data}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp approval_queue_placeholder(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-shield-check" class="size-5" /> Approval Queue
        </h2>
        <div class="text-center py-6 text-base-content/50">
          <.icon name="hero-wrench-screwdriver" class="size-8 mx-auto mb-2" />
          <p class="text-sm">Approval workflows will be available in a future release.</p>
        </div>
      </div>
    </div>
    """
  end

  attr :progress, :map, required: true

  defp progress_status_bar(assigns) do
    ~H"""
    <div class="alert alert-info py-2">
      <.icon name="hero-arrow-path" class="size-4 animate-spin" />
      <div class="flex-1">
        <span class="text-sm font-medium">{@progress.message}</span>
        <progress
          :if={@progress.percent}
          class="progress progress-info w-full mt-1"
          value={@progress.percent}
          max="100"
        />
      </div>
      <span :if={@progress.phase} class="badge badge-sm badge-ghost">{@progress.phase}</span>
    </div>
    """
  end

  # ── Shared Functional Components ─────────────────────────────────

  attr :state, :atom, required: true

  defp state_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", state_color(@state)]}>
      {@state}
    </span>
    """
  end

  attr :state, :atom, required: true

  defp task_state_badge(assigns) do
    ~H"""
    <span class={["badge badge-xs", task_state_color(@state)]}>
      {@state}
    </span>
    """
  end

  attr :outcome, :atom, required: true

  defp outcome_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", outcome_color(@outcome)]}>
      {@outcome}
    </span>
    """
  end

  attr :event, :any, required: true

  defp event_type_badge(assigns) do
    ~H"""
    <span class={["badge badge-xs", event_type_color(@event)]}>
      {event_type_label(@event)}
    </span>
    """
  end

  attr :event, :any, required: true

  defp event_details(assigns) do
    ~H"""
    <span>{format_event_details(@event)}</span>
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

  # ── Private Helpers ────────────────────────────────────────────────

  defp fetch_sprite_state(sprite_id) do
    case FleetManager.get_sprite_pid(sprite_id) do
      {:ok, pid} -> Sprite.get_state(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp refresh_sprite_state(socket) do
    case fetch_sprite_state(socket.assigns.sprite_id) do
      {:ok, sprite_state} ->
        assign(socket, :sprite_state, sprite_state)

      {:error, :not_found} ->
        assign(socket, :not_found, true)
    end
  end

  defp assign_sprite_tasks(socket) do
    case IntentStore.list_by_sprite(socket.assigns.sprite_id) do
      {:ok, intents} ->
        tasks = Enum.filter(intents, &Intent.task?/1)
        assign(socket, :sprite_tasks, tasks)

      _error ->
        assign(socket, :sprite_tasks, [])
    end
  end

  defp prepend_event(socket, event) do
    events =
      [event | socket.assigns.events]
      |> Enum.take(@max_events)

    assign(socket, :events, events)
  end

  defp prepend_protocol_event(socket, type, message) do
    event = %{
      type: type,
      message: message,
      timestamp: DateTime.utc_now(),
      id: System.unique_integer([:positive])
    }

    protocol_events =
      [event | socket.assigns.protocol_events]
      |> Enum.take(@max_events)

    socket
    |> assign(:protocol_events, protocol_events)
    |> prepend_event(event)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp create_and_propose_task(sprite_name, params) do
    repo = Map.get(params, "repo", "")
    task_kind = Map.get(params, "task_kind", "")
    instructions = Map.get(params, "instructions", "")

    with :ok <- validate_task_field(repo, "Repository"),
         :ok <- validate_task_field(task_kind, "Task kind"),
         :ok <- validate_task_field(instructions, "Instructions") do
      source = %{type: :operator, id: "dashboard"}

      opts =
        [task_kind: task_kind, instructions: instructions]
        |> maybe_add_opt(:base_branch, Map.get(params, "base_branch"))
        |> maybe_add_opt(:pr_title, Map.get(params, "pr_title"))

      with {:ok, intent} <- Intent.new_task(source, sprite_name, repo, opts) do
        Pipeline.propose(intent)
      end
    end
  end

  defp validate_task_field("", label), do: {:error, "#{label} is required."}
  defp validate_task_field(_value, _label), do: :ok

  defp default_task_form do
    %{
      "repo" => "",
      "task_kind" => "",
      "instructions" => "",
      "base_branch" => "",
      "pr_title" => ""
    }
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp truncate_id("int_" <> rest), do: "int_" <> String.slice(rest, 0, 8) <> "..."
  defp truncate_id(id), do: String.slice(id, 0, 16) <> "..."

  defp load_session_output(session_id) do
    with {:ok, pid} <- ExecSupervisor.get_session_pid(session_id),
         {:ok, output} <- ExecSession.get_output(pid) do
      Enum.map(output, fn entry ->
        %{
          id: System.unique_integer([:positive]),
          stream: entry.stream,
          data: entry.data,
          timestamp: entry.timestamp
        }
      end)
    else
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  defp load_exec_sessions(sprite_id) do
    ExecSupervisor.list_sessions_for_sprite(sprite_id)
    |> Enum.map(fn {_session_id, pid, _meta} ->
      try do
        case ExecSession.get_state(pid) do
          {:ok, state} -> state
          _ -> nil
        end
      catch
        :exit, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Exec session status colors
  defp exec_status_color(:running), do: "badge-success"
  defp exec_status_color(:connecting), do: "badge-info"
  defp exec_status_color(:closed), do: "badge-ghost"
  defp exec_status_color(_), do: "badge-ghost"

  # Exec output line styling
  defp exec_line_class(:stderr), do: "text-error"
  defp exec_line_class(:exit), do: "text-warning italic"
  defp exec_line_class(_), do: ""

  # Log level colors
  defp log_level_class(:error), do: "text-error"
  defp log_level_class(:warn), do: "text-warning"
  defp log_level_class(:debug), do: "text-base-content/50"
  defp log_level_class(_), do: ""

  # Log source colors
  defp log_source_class(:exec), do: "text-info"
  defp log_source_class(:reconciliation), do: "text-accent"
  defp log_source_class(:state_change), do: "text-primary"
  defp log_source_class(:service), do: "text-base-content/60"
  defp log_source_class(_), do: "text-base-content/60"

  # Log source labels
  defp format_log_source(:exec), do: "exec"
  defp format_log_source(:reconciliation), do: "recon"
  defp format_log_source(:state_change), do: "state"
  defp format_log_source(:service), do: "svc"
  defp format_log_source(_), do: "sys"

  defp format_log_timestamp(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  # State colors
  defp state_color(:cold), do: "badge-ghost"
  defp state_color(:warm), do: "badge-info"
  defp state_color(:running), do: "badge-success"
  defp state_color(_), do: "badge-ghost"

  # Task state colors
  defp task_state_color(:proposed), do: "badge-ghost"
  defp task_state_color(:classified), do: "badge-info"
  defp task_state_color(:awaiting_approval), do: "badge-warning"
  defp task_state_color(:approved), do: "badge-success"
  defp task_state_color(:running), do: "badge-info"
  defp task_state_color(:completed), do: "badge-success"
  defp task_state_color(:failed), do: "badge-error"
  defp task_state_color(:rejected), do: "badge-error"
  defp task_state_color(:canceled), do: "badge-ghost"
  defp task_state_color(_), do: "badge-ghost"

  # Outcome colors
  defp outcome_color(:success), do: "badge-success"
  defp outcome_color(:failure), do: "badge-error"
  defp outcome_color(:no_change), do: "badge-ghost"
  defp outcome_color(_), do: "badge-ghost"

  # Failure count coloring
  defp failure_color(0), do: "badge-success"
  defp failure_color(n) when n < 3, do: "badge-warning"
  defp failure_color(_), do: "badge-error"

  # Event type badge colors
  defp event_type_color(%StateChange{}), do: "badge-info"
  defp event_type_color(%ReconciliationResult{outcome: :success}), do: "badge-success"
  defp event_type_color(%ReconciliationResult{outcome: :failure}), do: "badge-error"
  defp event_type_color(%ReconciliationResult{}), do: "badge-ghost"
  defp event_type_color(%ApprovalNeeded{}), do: "badge-warning"
  defp event_type_color(%{type: "progress"}), do: "badge-info"
  defp event_type_color(%{type: "warning"}), do: "badge-warning"
  defp event_type_color(%{type: "checkpoint"}), do: "badge-success"
  defp event_type_color(_), do: "badge-ghost"

  # Event type labels
  defp event_type_label(%StateChange{}), do: "state_change"
  defp event_type_label(%ReconciliationResult{}), do: "reconciliation"
  defp event_type_label(%ApprovalNeeded{}), do: "approval"
  defp event_type_label(%{type: type}) when type in ~w(progress warning checkpoint), do: type
  defp event_type_label(_), do: "unknown"

  # Format event details for the timeline
  defp format_event_details(%StateChange{} = e) do
    "#{e.from_state} -> #{e.to_state}" <> if(e.reason, do: " (#{e.reason})", else: "")
  end

  defp format_event_details(%ReconciliationResult{} = e) do
    base = "#{e.outcome} in #{format_duration(e.duration_ms)}"
    if e.details, do: "#{base}: #{e.details}", else: base
  end

  defp format_event_details(%ApprovalNeeded{} = e) do
    "#{e.classification}: #{e.action}"
  end

  defp format_event_details(%{type: _, message: message}), do: message || ""

  defp format_event_details(_), do: ""

  # Generate a unique ID for each event in the timeline
  defp event_id(event) do
    :erlang.phash2({event, System.unique_integer()})
  end

  # Format milliseconds to a human-readable duration
  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

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

  defp maybe_discover_skills(socket) do
    sprite_id = socket.assigns.sprite_id

    case SkillDiscovery.discover(sprite_id) do
      {:ok, skills} -> assign(socket, :skills, skills)
      _ -> socket
    end
  rescue
    _ -> socket
  end
end
