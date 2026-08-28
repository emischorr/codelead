defmodule CodeLeadWeb.NavContext do
  @moduledoc """
  Assigns `@nav`, the single map every sidebar rendering in `CodeLeadWeb.Layouts`
  reads from. Attached as an `on_mount` hook to the authenticated `live_session`
  so navigation looks identical on every page instead of being reassembled by
  each LiveView.

  See `docs/navigation.md` for the sidebar contract and the project-memory
  mechanism this module implements.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias CodeLead.Agents.SubscriptionUsageCache
  alias CodeLead.Projects
  alias CodeLead.Tasks
  alias Phoenix.LiveView.Socket

  @doc """
  Resolves the selected project and the highlighted nav section, and installs
  the handler for the client's `"nav:restore_project"` push.

  `rate_limit` is read directly from `SubscriptionUsageCache` here rather
  than pushed in via `put_stats/2` — unlike `spend`, it isn't project-scoped,
  so every page (including `DashboardLive`) gets the same reading.

  `attention_count` and `agent_blocked?` are org-wide for the same reason —
  the sidebar pill covers every project, not just the open one — so they're
  read here rather than pushed in by the page.

  `project_stats` backs the project switcher's per-project running-pulse
  and attention badge, so it covers every project rather than just the
  open one — that needs the org-wide topic, not the page's own board
  subscription (if any).
  """
  def on_mount(:default, params, _session, socket) do
    projects = Projects.list_projects()
    {project, scope} = resolve_project(params, projects)

    if connected?(socket), do: Tasks.subscribe_org()

    nav = %{
      projects: projects,
      project: project,
      scope: scope,
      current: section(socket.view),
      attention_count: Tasks.total_attention_count(),
      agent_blocked?: Tasks.agent_blocked?(),
      project_stats: Tasks.project_summaries(),
      spend: nil,
      rate_limit: SubscriptionUsageCache.current()
    }

    {:cont,
     socket
     |> assign(:nav, nav)
     |> attach_hook(:nav_context, :handle_event, &handle_nav_event/3)
     |> attach_hook(:nav_context_info, :handle_info, &handle_nav_info/2)}
  end

  @doc """
  Feeds the project-scoped budget tile into `@nav`. Callers pass the spend
  they already loaded rather than the layout querying for it again. The
  attention pill is org-wide and refreshed independently, in `on_mount/4`
  and `handle_nav_info/2`.
  """
  @spec put_stats(Socket.t(), map() | nil) :: Socket.t()
  def put_stats(%{assigns: %{nav: nav}} = socket, spend) do
    assign(socket, :nav, %{nav | spend: spend})
  end

  ## Project resolution

  # Only the project routes carry a `:project_id`; everywhere else the sidebar
  # starts without a project and waits for the client to report the remembered
  # one, so a general page never flashes the wrong name.
  defp resolve_project(%{"project_id" => id}, projects),
    do: {find_project(projects, id), :project}

  defp resolve_project(_params, _projects), do: {nil, :general}

  defp find_project(_projects, nil), do: nil
  defp find_project(projects, id), do: Enum.find(projects, &(to_string(&1.id) == id))

  # The store element only pushes on general pages, where the selection is
  # deactivated — `scope` stays `:general`, so the project-scoped readouts
  # stay hidden.
  defp handle_nav_event("nav:restore_project", %{"id" => id}, %{assigns: %{nav: nav}} = socket) do
    case nav.scope do
      :general ->
        project = find_project(nav.projects, id) || List.first(nav.projects)
        {:halt, assign(socket, :nav, %{nav | project: project})}

      :project ->
        {:halt, socket}
    end
  end

  defp handle_nav_event(_event, _params, socket), do: {:cont, socket}

  ## Project stats

  # Always :cont — the page's own `handle_info` for the same message (board
  # reload, attention pill, task feed, …) still needs to run after this.
  defp handle_nav_info({:board_changed, _project_id, _task_id}, %{assigns: %{nav: nav}} = socket) do
    nav = %{
      nav
      | project_stats: Tasks.project_summaries(),
        attention_count: Tasks.total_attention_count(),
        agent_blocked?: Tasks.agent_blocked?()
    }

    {:cont, assign(socket, :nav, nav)}
  end

  defp handle_nav_info(_message, socket), do: {:cont, socket}

  ## Highlighted section

  defp section(view) do
    case Module.split(view) do
      ["CodeLeadWeb", "DashboardLive" | _] -> :dashboard
      ["CodeLeadWeb", "BoardLive" | _] -> :board
      ["CodeLeadWeb", "TaskLive" | _] -> :board
      ["CodeLeadWeb", "SettingsLive" | _] -> :settings
      ["CodeLeadWeb", "UserLive", "Settings" | _] -> :account
      _ -> nil
    end
  end
end
