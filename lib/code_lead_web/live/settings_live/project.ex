defmodule CodeLeadWeb.SettingsLive.Project do
  @moduledoc """
  Everything about one project: details and budgets, approve defaults, the
  PR template, linked repositories, the encrypted env store, and the
  per-work-type default reviewer sets.

  A full page rather than a modal over the list, because the sections are
  independent surfaces; the repository and env dialogs are patched over it.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Agents
  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLead.Projects.Repository
  alias CodeLead.Tasks.Task
  alias CodeLeadWeb.FlashMessages
  alias CodeLeadWeb.FormOptions
  alias CodeLeadWeb.SettingsLive.ProjectSections

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)

    {:ok,
     socket
     |> assign(page_title: project.name, project: project)
     |> assign_details_form(%{})
     |> assign_finalize_form()
     |> assign_pr_template_form()
     |> load_project()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new_repository}} = socket) do
    changeset = Projects.change_repository(%Repository{default_branch: "main"})

    {:noreply,
     socket
     |> assign(repository: %Repository{})
     |> assign(repository_form: to_form(changeset, as: "repository"))}
  end

  def handle_params(
        %{"repository_id" => id},
        _uri,
        %{assigns: %{live_action: :edit_repository}} = socket
      ) do
    repository = Projects.get_repository!(id)

    {:noreply,
     socket
     |> assign(repository: repository)
     |> assign(repository_form: to_form(Projects.change_repository(repository), as: "repository"))}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new_env}} = socket) do
    {:noreply, assign_env_form(socket, nil, %{"key" => "", "value" => "", "secret" => "true"})}
  end

  def handle_params(%{"key" => key}, _uri, %{assigns: %{live_action: :edit_env}} = socket) do
    entry = Enum.find(socket.assigns.env_keys, &(&1.key == key))

    params = %{
      "key" => key,
      "value" => entry.value || "",
      "secret" => to_string(entry.secret)
    }

    {:noreply, assign_env_form(socket, key, params)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, repository: nil, repository_form: nil, env_form: nil, env_key: nil)}
  end

  ## Details

  @impl true
  def handle_event("validate_details", %{"project" => params}, socket) do
    {:noreply, assign_details_form(socket, params)}
  end

  def handle_event("save_details", %{"project" => params}, socket) do
    case Projects.update_project(socket.assigns.project, blank_to_nil(params)) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project: project)
         |> put_flash(:info, "Project updated.")
         |> assign_details_form(%{})
         |> load_project()}

      {:error, changeset} ->
        {:noreply, assign(socket, details_form: to_form(changeset, as: "project"))}
    end
  end

  ## Finalize defaults

  def handle_event("save_finalize", %{"finalize" => params}, socket) do
    case Projects.put_finalize_defaults(socket.assigns.project, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project: project)
         |> put_flash(:info, "Approve defaults updated.")
         |> assign_finalize_form()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save the approve defaults.")}
    end
  end

  ## PR template

  def handle_event("save_pr_template", %{"pr_template" => %{"template" => template}}, socket) do
    case Projects.put_pr_template(socket.assigns.project, template) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project: project)
         |> put_flash(:info, "PR template updated.")
         |> assign_pr_template_form()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save the PR template.")}
    end
  end

  ## Repositories

  def handle_event(
        "save_repository",
        %{"repository" => params},
        %{assigns: %{live_action: :new_repository}} = socket
      ) do
    socket.assigns.project.id
    |> Projects.link_repository(params)
    |> repository_saved(socket)
  end

  def handle_event("save_repository", %{"repository" => params}, socket) do
    socket.assigns.repository
    |> Projects.update_repository(params)
    |> repository_saved(socket)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case id |> Projects.get_repository!() |> Projects.delete_repository() do
      {:ok, repository} ->
        {:noreply, socket |> put_flash(:info, "#{repository.name} unlinked.") |> load_project()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.delete_error(reason))}
    end
  end

  def handle_event("set_default_repository", %{"id" => id}, socket) do
    case id |> Projects.get_repository!() |> Projects.set_default_repository() do
      {:ok, repository} ->
        {:noreply,
         socket |> put_flash(:info, "#{repository.name} is now the default.") |> load_project()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not set that repository as default.")}
    end
  end

  ## Env store

  def handle_event("validate_env", %{"env" => params}, socket) do
    {:noreply, assign_env_form(socket, socket.assigns.env_key, params)}
  end

  def handle_event("save_env", %{"env" => params}, socket) do
    key = params |> Map.get("key", "") |> String.trim()
    value = Map.get(params, "value", "")
    secret = Map.get(params, "secret", "true") == "true"

    case Projects.put_env(socket.assigns.project.id, key, value, secret) do
      {:ok, _env} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{key} saved.")
         |> push_patch(to: ~p"/settings/projects/#{socket.assigns.project.id}")
         |> load_project()}

      {:error, changeset} ->
        {:noreply, assign_env_form(socket, socket.assigns.env_key, params, changeset.errors)}
    end
  end

  def handle_event("delete_env", %{"key" => key}, socket) do
    :ok = Projects.delete_env(socket.assigns.project.id, key)

    {:noreply, socket |> put_flash(:info, "#{key} removed.") |> load_project()}
  end

  ## Default reviewers

  def handle_event("save_reviewers", %{"work_type" => work_type} = params, socket) do
    agent_ids = params |> Map.get("agent_ids", []) |> Enum.map(&String.to_integer/1)
    work_type = String.to_existing_atom(work_type)

    case Agents.set_default_reviewers(socket.assigns.project.id, work_type, agent_ids) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Default #{work_type} reviewers saved.")
         |> load_project()}

      {:error, {:ineligible, ids}} ->
        message = "Not eligible as #{work_type} reviewers: #{Enum.join(ids, ", ")}."
        {:noreply, socket |> put_flash(:error, message) |> load_project()}
    end
  end

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title={@project.name} back={~p"/settings/projects"}>
        <:actions>
          <.button navigate={~p"/projects/#{@project.id}/board"}>Open board</.button>
        </:actions>
      </.settings_page_header>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto flex w-full max-w-4xl flex-col gap-3.5 p-4 sm:p-6">
          <ProjectSections.details form={@details_form} />
          <ProjectSections.finalize form={@finalize_form} />
          <ProjectSections.pr_template form={@pr_template_form} />
          <ProjectSections.repositories
            repositories={@repositories}
            project_id={@project.id}
            default_repository_name={@default_repository_name}
          />
          <ProjectSections.environment env_keys={@env_keys} project_id={@project.id} />
          <ProjectSections.agents project_agents={@project_agents} />
          <ProjectSections.default_reviewers reviewer_sets={@reviewer_sets} />
        </div>
      </div>

      <.modal
        :if={@live_action in [:new_repository, :edit_repository]}
        id="repository-modal"
        title={if @live_action == :new_repository, do: "Link repository", else: "Edit repository"}
        return_to={~p"/settings/projects/#{@project.id}"}
      >
        <.form for={@repository_form} id="repository-form" phx-submit="save_repository">
          <.input
            field={@repository_form[:name]}
            label="Repository name"
            placeholder="my-app"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@repository_form[:git_url]}
            label="Git URL"
            placeholder="git@github.com:me/my-app.git"
            spellcheck="false"
            required
          />
          <.input field={@repository_form[:default_branch]} label="Default branch" required />
          <.input
            field={@repository_form[:env_kind]}
            type="select"
            label="Execution environment"
            options={[{"Local only", :default}, {"Devcontainer", :devcontainer}]}
          />
          <p class="mb-4 text-[12px] leading-relaxed text-text3">
            Devcontainer runs this repository's tasks in the environment its
            own <code class="font-mono">.devcontainer</code>
            setup describes (services included) — tasks can then choose
            Container execution (Local stays the default). Private HTTPS
            repositories need a <code class="font-mono">GITHUB_TOKEN</code>
            or <code class="font-mono">GITLAB_TOKEN</code>
            in the environment section below. SSH URLs use this machine's key.
          </p>
          <.input
            field={@repository_form[:devcontainer_path]}
            label="Devcontainer config path"
            placeholder=".devcontainer/devcontainer.json"
            spellcheck="false"
          />
          <p class="mb-4 text-[12px] leading-relaxed text-text3">
            Optional. Leave blank to auto-discover the config in the
            devcontainer spec's search order; set it to pin one of several
            configs in the repo.
          </p>
          <.input
            field={@repository_form[:preview_port]}
            type="number"
            label="Preview port"
            placeholder="5173"
            min="1"
            max="65535"
          />
          <p class="mb-4 text-[12px] leading-relaxed text-text3">
            The port a dev server inside this repository's tasks listens on.
            Declaring it enables the live preview in the Review tab; the
            serve command receives it as <code class="font-mono">PREVIEW_PORT</code>. Unique per
            repository across this instance — CodeLead's own port is taken.
            Leave blank to review by diff only.
          </p>
          <.input
            field={@repository_form[:preview_command]}
            label="Preview command"
            placeholder="npm run dev -- --host"
            spellcheck="false"
          />
          <p class="mb-4 text-[12px] leading-relaxed text-text3">
            Optional. The command that starts the dev server on the preview
            port — declaring it puts a Start preview button on the Review
            tab. It runs in the worktree with the project env plus <code class="font-mono">PREVIEW_BASE_PATH</code>; without it,
            start the server yourself from the task's Terminal. It must be a
            single command — a <code class="font-mono">VAR=value</code>
            prefix
            is fine, chaining with <code class="font-mono">&amp;&amp;</code>
            or <code class="font-mono">|</code>
            is not.
          </p>

          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/settings/projects/#{@project.id}"}>Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Saving…">Save</.button>
          </div>
        </.form>
      </.modal>

      <.modal
        :if={@live_action in [:new_env, :edit_env]}
        id="env-modal"
        title={if @live_action == :new_env, do: "Add variable", else: "Edit variable"}
        return_to={~p"/settings/projects/#{@project.id}"}
      >
        <.form for={@env_form} id="env-form" phx-change="validate_env" phx-submit="save_env">
          <.input
            field={@env_form[:key]}
            label="Name"
            placeholder="GITHUB_TOKEN"
            spellcheck="false"
            readonly={@live_action == :edit_env}
            required
          />
          <.input
            field={@env_form[:value]}
            type={if env_secret?(@env_form), do: "password", else: "text"}
            label="Value"
            autocomplete="new-password"
            data-1p-ignore="true"
            data-lpignore="true"
            data-bwignore="true"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input type="checkbox" field={@env_form[:secret]} label="Encrypt this value" />
          <p class="mb-4 text-[12px] leading-relaxed text-text3">
            <%= if env_secret?(@env_form) do %>
              Letters, digits and underscores; must not start with a digit. Encrypted at rest and
              never displayed again.
            <% else %>
              Letters, digits and underscores; must not start with a digit. Stored as plain text —
              visible in this UI and editable later.
            <% end %>
          </p>

          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/settings/projects/#{@project.id}"}>Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Saving…">Save</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  ## Loading

  defp load_project(socket) do
    project_id = socket.assigns.project.id
    forge_vars = [Git.token_var(:github), Git.token_var(:gitlab)]

    repositories =
      Enum.map(Projects.list_repositories(project_id), fn repository ->
        %{tasks: tasks} = Projects.repository_usage(repository.id)
        Map.put(repository, :delete_reason, repository_reason(tasks))
      end)

    default_repository_name =
      case Enum.find(repositories, & &1.is_default) do
        nil -> nil
        repository -> repository.name
      end

    env_keys =
      Enum.map(Projects.list_env_keys(project_id), fn entry ->
        Map.put(entry, :forge_token?, entry.key in forge_vars)
      end)

    reviewer_sets =
      Enum.map(FormOptions.work_type_values(), fn work_type ->
        %{
          work_type: work_type,
          candidates: Agents.eligible_reviewers(work_type, project_id),
          selected_ids: Enum.map(Agents.default_reviewers(project_id, work_type), & &1.id)
        }
      end)

    assign(socket,
      repositories: repositories,
      default_repository_name: default_repository_name,
      env_keys: env_keys,
      project_agents: Agents.list_project_agents(project_id),
      reviewer_sets: reviewer_sets
    )
  end

  defp assign_details_form(socket, params) do
    changeset =
      socket.assigns.project
      |> Projects.change_project(params)
      |> Map.put(:action, if(params == %{}, do: nil, else: :validate))

    assign(socket, details_form: to_form(changeset, as: "project"))
  end

  # A plain map form, not a changeset: these live in the project's
  # jsonb `settings` and are written through `put_finalize_defaults/2`,
  # which merges rather than replacing the column.
  defp assign_finalize_form(socket) do
    defaults = Projects.finalize_defaults(socket.assigns.project.id)

    params = %{
      "repo" => mode_value(defaults.repo, :repo),
      "folder" => mode_value(defaults.folder, :folder),
      "commit_path" => defaults.commit_path
    }

    assign(socket, finalize_form: to_form(params, as: "finalize"))
  end

  # An unset default still has to select something, so the select shows
  # the built-in the finalizer would fall back to.
  defp mode_value(nil, target), do: to_string(Task.default_finalize_mode(target))
  defp mode_value(mode, _target), do: to_string(mode)

  # Prefilled with the effective template (custom or built-in), so the
  # field always shows what the finalizer would actually render.
  defp assign_pr_template_form(socket) do
    template = Projects.pr_template(socket.assigns.project.id)

    assign(socket, pr_template_form: to_form(%{"template" => template}, as: "pr_template"))
  end

  defp assign_env_form(socket, key, params, errors \\ []) do
    socket
    |> assign(env_key: key)
    |> assign(env_form: to_form(params, as: "env", errors: errors))
  end

  defp env_secret?(form), do: Phoenix.HTML.Form.normalize_value("checkbox", form[:secret].value)

  defp repository_saved({:ok, repository}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "#{repository.name} saved.")
     |> push_patch(to: ~p"/settings/projects/#{socket.assigns.project.id}")
     |> load_project()}
  end

  defp repository_saved({:error, changeset}, socket) do
    {:noreply, assign(socket, repository_form: to_form(changeset, as: "repository"))}
  end

  # An empty number input arrives as "", which would fail the integer cast
  # rather than clearing the limit.
  defp blank_to_nil(params) do
    Map.new(params, fn
      {key, ""} when key in ["budget_limit_cents", "budget_limit_tokens"] -> {key, nil}
      pair -> pair
    end)
  end

  defp repository_reason(0), do: nil
  defp repository_reason(count), do: FlashMessages.delete_error({:has_tasks, count})
end
