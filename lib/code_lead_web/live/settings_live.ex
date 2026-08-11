defmodule CodeLeadWeb.SettingsLive do
  @moduledoc """
  The settings overview: one tile per administrable section, each carrying
  enough of a summary that the page answers "what does this instance look
  like?" without a click.

  Everything the first-run wizard creates is editable from here. The
  organization tile is a placeholder — see `docs/web-ui.md` for why editing
  `organizations.settings` needs a merging setter first.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Accounts
  alias CodeLead.Agents
  alias CodeLead.Projects
  alias CodeLeadWeb.FormOptions

  @impl true
  def mount(_params, _session, socket) do
    users = Accounts.list_users()
    providers = Agents.list_providers()
    agents = Agents.list_org_agents()
    projects = Projects.list_projects()

    {:ok,
     socket
     |> assign(page_title: "Settings")
     |> assign(organization: Accounts.get_organization!())
     |> assign(users: users, providers: providers, agents: agents, projects: projects)}
  end

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="Settings" />

      <div class="mx-auto w-full max-w-5xl p-4 sm:p-6">
        <p class="mb-5 text-[13px] text-text2">
          Everything the setup wizard created, plus the people who can sign in.
        </p>

        <div class="grid gap-3.5 sm:grid-cols-2 lg:grid-cols-3">
          <.settings_tile
            id="settings-tile-users"
            icon="hero-users"
            label="Users"
            stat={count(length(@users), "user")}
            detail={users_detail(@users)}
            navigate={~p"/settings/users"}
          />
          <.settings_tile
            id="settings-tile-providers"
            icon="hero-cloud"
            label="Providers"
            stat={count(length(@providers), "provider")}
            detail={join_names(Enum.map(@providers, &FormOptions.provider_kind_label(&1.kind)))}
            navigate={~p"/settings/providers"}
          />
          <.settings_tile
            id="settings-tile-agents"
            icon="hero-sparkles"
            label="Agents"
            stat={count(length(@agents), "org agent")}
            detail={agents_detail(@agents)}
            navigate={~p"/settings/agents"}
          />
          <.settings_tile
            id="settings-tile-projects"
            icon="hero-folder"
            label="Projects"
            stat={count(length(@projects), "project")}
            detail={join_names(Enum.map(@projects, & &1.name))}
            navigate={~p"/settings/projects"}
          />
          <.settings_tile
            id="settings-tile-organization"
            icon="hero-building-office"
            label="Organization"
            stat={@organization.name}
            detail="Budget limits and instance config"
          />
        </div>

        <div class="mt-3.5">
          <.section_card label="Your account">
            <p class="text-[13px] text-text2">
              Your own email, password and preferences live on the account page.
            </p>
            <div>
              <.button navigate={~p"/users/settings"}>Open account settings</.button>
            </div>
          </.section_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Tile copy

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp users_detail(users) do
    case Enum.count(users, &is_nil(&1.confirmed_at)) do
      0 -> join_names(Enum.map(users, & &1.email))
      1 -> "1 invite pending"
      pending -> "#{pending} invites pending"
    end
  end

  defp agents_detail([]), do: "None yet — nothing can run without one"

  defp agents_detail(agents) do
    agents |> Enum.map(&to_string(&1.work_type)) |> Enum.uniq() |> join_names()
  end

  defp join_names([]), do: nil

  defp join_names(names) do
    case Enum.split(names, 3) do
      {shown, []} -> Enum.join(shown, " · ")
      {shown, rest} -> Enum.join(shown, " · ") <> " +#{length(rest)}"
    end
  end
end
