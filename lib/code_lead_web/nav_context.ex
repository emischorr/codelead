defmodule CodeLeadWeb.NavContext do
  @moduledoc """
  Assigns `@nav`, the single map every sidebar rendering in `CodeLeadWeb.Layouts`
  reads from. Attached as an `on_mount` hook to the authenticated `live_session`
  so navigation looks identical on every page instead of being reassembled by
  each LiveView.

  See `docs/navigation.md` for the sidebar contract and the project-memory
  mechanism this module implements.
  """

  use CodeLeadWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_navigate: 2, redirect: 2]

  alias CodeLead.Accounts
  alias CodeLead.Accounts.Policy
  alias CodeLead.Accounts.Scope
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
    current_scope = socket.assigns.current_scope
    projects = Projects.list_projects(current_scope)
    {project, scope} = resolve_project(params, projects)
    ids = visible_ids(current_scope)

    if connected?(socket) do
      Tasks.subscribe_org()
      Accounts.subscribe_user(current_scope.user.id)
    end

    nav = %{
      projects: projects,
      project: project,
      scope: scope,
      current: section(socket.view),
      attention_count: Tasks.total_attention_count(ids),
      agent_blocked?: Tasks.agent_blocked?(ids),
      project_stats: Tasks.project_summaries(ids),
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
  The project-id filter the caller's readouts must use: nil for admins
  (unrestricted), the membership ids otherwise.
  """
  @spec visible_ids(Scope.t() | nil) :: [pos_integer()] | nil
  def visible_ids(current_scope) do
    if Scope.admin?(current_scope), do: nil, else: Scope.project_ids(current_scope)
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
    ids = visible_ids(socket.assigns.current_scope)

    nav = %{
      nav
      | project_stats: Tasks.project_summaries(ids),
        attention_count: Tasks.total_attention_count(ids),
        agent_blocked?: Tasks.agent_blocked?(ids)
    }

    {:cont, assign(socket, :nav, nav)}
  end

  # A membership or role write for this user landed (see
  # `Accounts.notify_scope_changed/1`). Rebuild the scope in place when
  # the page stays valid; anything that might change which gates apply —
  # a different instance role, or losing sight of the open project —
  # forces a remount so the live_session's own hooks re-run.
  defp handle_nav_info({:scope_changed, _user_id}, socket) do
    old_scope = socket.assigns.current_scope

    case Scope.refresh(old_scope) do
      nil ->
        {:halt, redirect(socket, to: ~p"/users/log-in")}

      scope ->
        if scope.role != old_scope.role or lost_open_project?(scope, socket.assigns.nav) do
          {:halt, push_navigate(socket, to: ~p"/")}
        else
          ids = visible_ids(scope)

          nav = %{
            socket.assigns.nav
            | projects: Projects.list_projects(scope),
              project_stats: Tasks.project_summaries(ids),
              attention_count: Tasks.total_attention_count(ids),
              agent_blocked?: Tasks.agent_blocked?(ids)
          }

          {:cont, socket |> assign(:current_scope, scope) |> assign(:nav, nav)}
        end
    end
  end

  defp handle_nav_info(_message, socket), do: {:cont, socket}

  defp lost_open_project?(_scope, %{project: nil}), do: false

  defp lost_open_project?(scope, %{project: project}) do
    not Policy.can?(scope, :view_project, project.id)
  end

  ## Highlighted section

  defp section(view) do
    case Module.split(view) do
      ["CodeLeadWeb", "DashboardLive" | _] -> :dashboard
      ["CodeLeadWeb", "BoardLive" | _] -> :board
      ["CodeLeadWeb", "TaskLive" | _] -> :board
      ["CodeLeadWeb", "ArchiveLive" | _] -> :archive
      ["CodeLeadWeb", "SettingsLive" | _] -> :settings
      ["CodeLeadWeb", "UserLive", "Settings" | _] -> :account
      _ -> nil
    end
  end
end
