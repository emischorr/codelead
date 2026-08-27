defmodule CodeLeadWeb.SettingsLive.Projects do
  @moduledoc """
  The project list. Creating accepts either a plain name or a GitHub/GitLab
  repository URL: a URL `CodeLead.Git.forge/1` recognizes creates the
  project and links that repository in one step, deriving both names from
  it; anything else becomes the project name verbatim. Every other
  repository link, and both names, stay editable on the detail page.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLeadWeb.FlashMessages

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Projects") |> load_projects()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    {:noreply, assign_source(socket, "")}
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, form: nil, classification: nil)}

  @impl true
  def handle_event("validate", %{"project" => %{"source" => source}}, socket) do
    {:noreply, assign_source(socket, source)}
  end

  def handle_event("save", %{"project" => %{"source" => source}}, socket) do
    socket = assign_source(socket, source)

    case socket.assigns.classification do
      {:name, name} ->
        %{"name" => name}
        |> Projects.create_project()
        |> handle_created(socket, "Link its repositories next.")

      {:repo, kind, owner, repo, git_url} ->
        %{"name" => repo}
        |> Projects.create_project_with_repository(%{"name" => repo, "git_url" => git_url})
        |> handle_created(socket, "Linked its #{Git.host(kind)} repository #{owner}/#{repo}.")

      _not_submittable ->
        {:noreply, socket}
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
          <.input
            field={@form[:source]}
            label="Project name or repository URL"
            placeholder="my-project or https://github.com/acme/widgets"
            required
            phx-mounted={JS.focus()}
          />
          <p :if={hint(@classification)} class="mb-4 text-[12px] text-text3">
            {hint(@classification)}
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

  ## Name-or-URL field

  defp assign_source(socket, source) do
    classification = classify_source(source)

    socket
    |> assign(source: source, classification: classification)
    |> assign(form: source_form(source, classification_errors(classification)))
  end

  defp source_form(source, errors),
    do: to_form(%{"source" => source}, as: "project", errors: errors)

  # A blank source is left to the input's `required` attribute; a bare
  # name never resembles `https://`/`git@`, so only text that actually
  # looks like a URL is run through `Git.forge/1`.
  defp classify_source(source) do
    trimmed = String.trim(source)

    cond do
      trimmed == "" -> :blank
      looks_like_url?(trimmed) -> classify_url(trimmed)
      true -> {:name, trimmed}
    end
  end

  defp classify_url(url) do
    case Git.forge(url) do
      {kind, owner, repo} -> {:repo, kind, owner, repo, url}
      :other -> {:invalid_url, url}
    end
  end

  defp looks_like_url?(value),
    do: String.contains?(value, "://") or String.starts_with?(value, "git@")

  defp classification_errors({:invalid_url, _url}) do
    [
      source:
        {"only github.com and gitlab.com repository URLs are auto-detected — enter a " <>
           "project name instead, or paste a plain repository URL", []}
    ]
  end

  defp classification_errors(_other), do: []

  defp hint({:repo, kind, owner, repo, _url}) do
    "Will create project \"#{repo}\" and link its #{Git.host(kind)} repository " <>
      "#{owner}/#{repo}. Both names can be changed afterwards."
  end

  defp hint({:invalid_url, _url}), do: nil
  defp hint(_other), do: "You'll link repositories and set budgets on the next screen."

  defp handle_created({:ok, project}, socket, note) do
    {:noreply,
     socket
     |> put_flash(:info, "#{project.name} created. #{note}")
     |> push_navigate(to: ~p"/settings/projects/#{project.id}")}
  end

  defp handle_created({:error, changeset}, socket, _note) do
    {:noreply,
     assign(socket, form: source_form(socket.assigns.source, source: first_error(changeset)))}
  end

  defp handle_created({:error, _tag, changeset}, socket, _note) do
    handle_created({:error, changeset}, socket, nil)
  end

  defp first_error(changeset) do
    case changeset.errors do
      [{_field, error} | _rest] -> error
      [] -> {"could not be saved", []}
    end
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
