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
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias CodeLead.Agents.SubscriptionUsageCache
  alias CodeLead.Projects
  alias Phoenix.LiveView.Socket

  @doc """
  Resolves the selected project and the highlighted nav section, and installs
  the handler for the client's `"nav:restore_project"` push.

  `rate_limit` is read directly from `SubscriptionUsageCache` here rather
  than pushed in via `put_stats/3` — unlike `spend`, it isn't project-scoped,
  so every page (including `DashboardLive`) gets the same reading.
  """
  def on_mount(:default, params, _session, socket) do
    projects = Projects.list_projects()
    {project, scope} = resolve_project(params, projects)

    nav = %{
      projects: projects,
      project: project,
      scope: scope,
      current: section(socket.view),
      attention_count: 0,
      spend: nil,
      rate_limit: SubscriptionUsageCache.current()
    }

    {:cont,
     socket
     |> assign(:nav, nav)
     |> attach_hook(:nav_context, :handle_event, &handle_nav_event/3)}
  end

  @doc """
  Feeds the project-scoped readouts — the attention pill and the budget tile —
  into `@nav`. Callers pass the values they already loaded rather than the
  layout querying for them again.
  """
  @spec put_stats(Socket.t(), non_neg_integer(), map() | nil) :: Socket.t()
  def put_stats(%{assigns: %{nav: nav}} = socket, attention_count, spend) do
    assign(socket, :nav, %{nav | attention_count: attention_count, spend: spend})
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
