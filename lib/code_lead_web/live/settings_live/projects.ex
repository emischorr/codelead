defmodule CodeLeadWeb.SettingsLive.Projects do
  @moduledoc """
  The project list. Creating asks only for a name and then opens the detail
  page — repositories are linked in exactly one place, unlike the wizard's
  combined form.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Projects
  alias CodeLead.Projects.Project
  alias CodeLeadWeb.FlashMessages

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Projects") |> load_projects()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    changeset = Projects.change_project(%Project{})
    {:noreply, assign(socket, form: to_form(changeset, as: "project"))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, form: nil)}

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    changeset =
      %Project{} |> Projects.change_project(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "project"))}
  end

  def handle_event("save", %{"project" => params}, socket) do
    case Projects.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{project.name} created. Link its repositories next.")
         |> push_navigate(to: ~p"/settings/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "project"))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case id |> Projects.get_project!() |> Projects.delete_project() do
      {:ok, project} ->
        {:noreply, socket |> put_flash(:info, "#{project.name} deleted.") |> load_projects()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.delete_error(reason))}
    end
  end

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="Projects" back={~p"/settings"}>
        <:actions>
          <.button id="new-project" variant="primary" patch={~p"/settings/projects/new"}>
            Add project
          </.button>
        </:actions>
      </.settings_page_header>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto w-full max-w-4xl p-4 sm:p-6">
          <.section_card label="Product workspaces">
            <div :if={@projects == []}>
              <.empty_state icon="hero-folder" title="No projects yet">
                A project holds the tasks, the linked repositories and the env store.
              </.empty_state>
            </div>

            <div id="project-list">
              <.list_row
                :for={project <- @projects}
                id={"project-row-#{project.id}"}
                title={project.name}
                subtitle={repo_line(project.repository_count)}
                navigate={~p"/settings/projects/#{project.id}"}
              >
                <:meta>
                  <span>{task_line(project.task_count)}</span>
                  <span :if={project.budget_limit_cents} class="font-mono">
                    {Format.cents(project.budget_limit_cents)}/mo
                  </span>
                </:meta>
                <:actions>
                  <.button navigate={~p"/settings/projects/#{project.id}"}>Open</.button>
                  <.delete_button
                    id={"delete-project-#{project.id}"}
                    value={project.id}
                    reason={usage_reason(project.task_count)}
                    confirm={
                    "Delete #{project.name}? Its repositories, env store and project agents go with it. " <>
                      "The managed clone on disk is left in place."
                  }
                  />
                </:actions>
              </.list_row>
            </div>
          </.section_card>
        </div>
      </div>

      <.modal
        :if={@live_action == :new}
        id="project-modal"
        title="Add project"
        return_to={~p"/settings/projects"}
      >
        <.form for={@form} id="project-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:name]} label="Project name" required phx-mounted={JS.focus()} />
          <p class="mb-4 text-[12px] text-text3">
            You'll link repositories and set budgets on the next screen.
          </p>

          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/settings/projects"}>Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Creating…">Create</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  ## Loading

  defp load_projects(socket) do
    projects =
      Enum.map(Projects.list_projects(), fn project ->
        %{tasks: task_count} = Projects.project_usage(project.id)

        project
        |> Map.put(:task_count, task_count)
        |> Map.put(:repository_count, length(Projects.list_repositories(project.id)))
      end)

    assign(socket, projects: projects)
  end

  ## Row copy

  defp repo_line(0), do: "No repository linked"
  defp repo_line(1), do: "1 repository"
  defp repo_line(count), do: "#{count} repositories"

  defp task_line(1), do: "1 task"
  defp task_line(count), do: "#{count} tasks"

  defp usage_reason(0), do: nil
  defp usage_reason(count), do: FlashMessages.delete_error({:has_tasks, count})
end
