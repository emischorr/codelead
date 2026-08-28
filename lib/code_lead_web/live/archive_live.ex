defmodule CodeLeadWeb.ArchiveLive do
  @moduledoc """
  A project's full task history — archived and not, every state. Separate
  from the board on purpose: this page exists to *find* an old task, not to
  move one through the workflow, so it carries no state-changing actions.
  See `docs/web-ui.md` for the split against the board's own (future) list
  view, which is a different, narrower thing — a view of the same working
  set the Kanban board shows.
  """
  use CodeLeadWeb, :live_view

  alias CodeLead.Agents
  alias CodeLead.Projects
  alias CodeLead.Tasks
  alias CodeLeadWeb.FormOptions

  @sort_fields [:id, :priority, :inserted_at, :completed_at]
  @sort_options [
    {"Task ID", "id"},
    {"Priority", "priority"},
    {"Created", "inserted_at"},
    {"Done", "completed_at"}
  ]

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    project = Projects.get_project!(project_id)

    if connected?(socket), do: Tasks.subscribe_board(project.id)

    agents = Agents.list_agents(project.id)
    repositories = Projects.list_repositories(project.id)

    {:ok,
     assign(socket,
       page_title: "Archive",
       project: project,
       agents: agents,
       repositories: repositories,
       agents_by_id: Map.new(agents, &{&1.id, &1}),
       repositories_by_id: Map.new(repositories, &{&1.id, &1})
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)

    {:noreply,
     socket
     |> assign(filters: filters, filter_form: to_form(filters_to_params(filters), as: :filters))
     |> load_tasks()}
  end

  @impl true
  def handle_event("filter_change", %{"filters" => raw}, socket) do
    {:noreply,
     push_patch(socket, to: archive_path(socket.assigns.project.id, raw), replace: true)}
  end

  def handle_event("toggle_dir", _params, socket) do
    dir = if socket.assigns.filters.sort_dir == :asc, do: :desc, else: :asc
    raw = filters_to_params(%{socket.assigns.filters | sort_dir: dir})

    {:noreply,
     push_patch(socket, to: archive_path(socket.assigns.project.id, raw), replace: true)}
  end

  @impl true
  def handle_info({:board_changed, _project_id, _task_id}, socket) do
    {:noreply, load_tasks(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_tasks(socket) do
    tasks = Tasks.list_all(socket.assigns.project.id, Map.to_list(socket.assigns.filters))
    assign(socket, tasks: tasks)
  end

  defp archive_path(project_id, params), do: ~p"/projects/#{project_id}/archive?#{params}"

  ## Filter/sort param parsing — URL query string is the single source of
  ## truth for the current view, so the page is bookmarkable and back/forward
  ## works, same idiom as `select_column` in BoardLive.

  defp parse_filters(params) do
    %{
      work_type: parse_enum(params["work_type"], FormOptions.work_type_values()),
      agent_id: parse_int(params["agent_id"]),
      repository_id: parse_int(params["repository_id"]),
      include_archived: params["archived"] != "false",
      sort_by: parse_enum(params["sort"], @sort_fields) || :inserted_at,
      sort_dir: parse_enum(params["dir"], [:asc, :desc]) || :desc
    }
  end

  defp filters_to_params(filters) do
    %{
      "work_type" => to_param(filters.work_type),
      "agent_id" => to_param(filters.agent_id),
      "repository_id" => to_param(filters.repository_id),
      "archived" => to_string(filters.include_archived),
      "sort" => to_param(filters.sort_by),
      "dir" => to_param(filters.sort_dir)
    }
  end

  defp to_param(nil), do: ""
  defp to_param(value), do: to_string(value)

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _not_an_int -> nil
    end
  end

  defp parse_enum(nil, _values), do: nil
  defp parse_enum(value, values), do: Enum.find(values, &(Atom.to_string(&1) == value))

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <header class="flex h-[58px] shrink-0 items-center gap-3.5 border-b border-border bg-surface px-4 sm:px-5">
        <Layouts.sidebar_toggle />
        <.project_dot color={@project.color} />
        <span class="truncate text-[15px] font-semibold text-text">{@project.name}</span>
        <span class="hidden text-sm text-text2 sm:inline">Archive</span>
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto p-4 sm:p-5">
        <.form
          for={@filter_form}
          id="archive-filters"
          phx-change="filter_change"
          class="mb-4 flex flex-wrap items-end gap-3"
        >
          <.input
            field={@filter_form[:work_type]}
            type="select"
            label="Work type"
            prompt="All"
            options={FormOptions.work_types()}
            class="w-40"
          />
          <.input
            field={@filter_form[:agent_id]}
            type="select"
            label="Executor"
            prompt="All"
            options={Enum.map(@agents, &{&1.name, &1.id})}
            class="w-40"
          />
          <.input
            field={@filter_form[:repository_id]}
            type="select"
            label="Repository"
            prompt="All"
            options={Enum.map(@repositories, &{&1.name, &1.id})}
            class="w-40"
          />
          <.input
            field={@filter_form[:archived]}
            type="checkbox"
            label="Show archived"
            checked={@filters.include_archived}
          />
          <%!-- Not user-facing — carries the current sort direction along with
                every other filter change, since only `toggle_dir` should flip
                it. Without this, submitting the form (a filter or the sort
                field) would silently drop `dir` and reset it to the default. --%>
          <.input field={@filter_form[:dir]} type="hidden" />
          <div class="ml-auto flex items-end gap-1.5">
            <.input
              field={@filter_form[:sort]}
              type="select"
              label="Sort by"
              options={sort_options()}
              class="w-36"
            />
            <button
              type="button"
              phx-click="toggle_dir"
              id="archive-sort-dir"
              title={if @filters.sort_dir == :asc, do: "Ascending", else: "Descending"}
              aria-label="Toggle sort direction"
              class="flex h-[38px] shrink-0 cursor-pointer items-center justify-center rounded-lg border border-border bg-surface px-2.5 text-text2 hover:bg-surface2"
            >
              <.icon
                name={
                  if @filters.sort_dir == :asc, do: "hero-bars-arrow-up", else: "hero-bars-arrow-down"
                }
                class="size-4"
              />
            </button>
          </div>
        </.form>

        <.empty_state :if={@tasks == []} title="No tasks match these filters" icon="hero-inbox" />

        <div :if={@tasks != []} id="archive-rows" class="flex flex-col gap-2">
          <.archive_row
            :for={task <- @tasks}
            id={"archive-row-#{task.id}"}
            task={task}
            project_id={@project.id}
            agent={@agents_by_id[task.agent_id]}
            repository={@repositories_by_id[task.repository_id]}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp sort_options, do: @sort_options

  attr :id, :string, required: true
  attr :task, :map, required: true
  attr :project_id, :integer, required: true
  attr :agent, :map, default: nil
  attr :repository, :map, default: nil

  defp archive_row(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={~p"/projects/#{@project_id}/tasks/#{@task.id}"}
      class={[
        "flex items-center gap-3 rounded-xl border border-border bg-surface p-3 transition-shadow hover:shadow-md",
        @task.archived_at && "opacity-80"
      ]}
    >
      <span class="w-14 shrink-0 font-mono text-[11px] text-text3">#{@task.id}</span>
      <.priority_icon priority={@task.priority} class="size-4 shrink-0" />
      <span class="min-w-0 flex-1 truncate text-[13.5px] font-medium text-text">{@task.title}</span>
      <span class="hidden shrink-0 font-mono text-[11px] text-text3 sm:inline">
        {@task.work_type}
      </span>
      <span class="hidden w-32 shrink-0 truncate text-[11.5px] text-text2 md:inline">
        {(@repository && @repository.name) || "—"}
      </span>
      <.agent_pill
        :if={@agent}
        name={@agent.name}
        harness={@agent.harness}
        class="hidden shrink-0 lg:inline-flex"
      />
      <span :if={!@agent} class="hidden shrink-0 text-[11px] text-text3 lg:inline">Unassigned</span>
      <.badge :if={@task.archived_at} variant={:neutral} class="shrink-0">Archived</.badge>
      <.state_badge state={@task.state} run_state={@task.run_state} />
    </.link>
    """
  end
end
