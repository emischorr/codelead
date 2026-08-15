defmodule CodeLeadWeb.SettingsLive.ProjectSections do
  @moduledoc """
  The sections of the project settings page. Presentation only — every
  event is handled by `CodeLeadWeb.SettingsLive.Project`.
  """

  use CodeLeadWeb, :html

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLeadWeb.FormOptions

  @doc """
  Name and budget limits. Budgets are entered in cents, which is how they are
  stored and how the scheduler reads them.
  """
  attr :form, Phoenix.HTML.Form, required: true

  def details(assigns) do
    ~H"""
    <.section_card label="Details">
      <.form
        for={@form}
        id="project-details-form"
        phx-change="validate_details"
        phx-submit="save_details"
      >
        <.input field={@form[:name]} label="Project name" required />

        <div class="grid gap-x-3 sm:grid-cols-2">
          <div>
            <.input
              field={@form[:budget_limit_cents]}
              type="number"
              min="0"
              label="Monthly cost limit (cents)"
              placeholder="No limit"
            />
            <p class="-mt-1 mb-2 text-[12px] text-text3">
              {budget_hint(@form[:budget_limit_cents].value)}
            </p>
          </div>
          <.input
            field={@form[:budget_limit_tokens]}
            type="number"
            min="0"
            label="Monthly token limit"
            placeholder="No limit"
          />
        </div>

        <p class="mb-4 text-[12px] leading-relaxed text-text3">
          Limits cover the current calendar month (UTC) and reset on the 1st. A run that would push
          the project past one is held in the queue rather than started. Leave blank for no limit.
        </p>

        <div class="flex justify-end">
          <.button variant="primary" type="submit" phx-disable-with="Saving…">Save details</.button>
        </div>
      </.form>
    </.section_card>
    """
  end

  @doc """
  What Approve → Done does by default, per target. Every task inherits
  these and may override its own.
  """
  attr :form, Phoenix.HTML.Form, required: true

  def finalize(assigns) do
    ~H"""
    <.section_card label="On approve">
      <.form for={@form} id="project-finalize-form" phx-submit="save_finalize">
        <.input
          field={@form[:repo]}
          type="select"
          label="Repository tasks"
          options={FormOptions.finalize_modes(:repo)}
        />
        <.input
          field={@form[:folder]}
          type="select"
          label="Folder tasks"
          options={FormOptions.finalize_modes(:folder)}
        />
        <.input
          field={@form[:commit_path]}
          label="Artifact path"
          placeholder={CodeLead.Projects.default_commit_path()}
        />

        <p class="mb-4 text-[12px] leading-relaxed text-text3">
          Merge and squash push straight to the repository's default branch and then delete the
          feature branch — a protected branch will refuse that, so use Pull request there.
          <em>Commit to path</em>
          lands a folder task's artifact in <code>&lt;path&gt;/task-&lt;id&gt;-&lt;slug&gt;/</code>
          on its own branch. A task can override any of this on its own page.
        </p>

        <div class="flex justify-end">
          <.button variant="primary" type="submit" phx-disable-with="Saving…">
            Save defaults
          </.button>
        </div>
      </.form>
    </.section_card>
    """
  end

  @doc """
  The PR/MR description template used when Approve opens a pull request.
  Placeholders are substituted at creation time; a blank field reverts
  to the built-in default.
  """
  attr :form, Phoenix.HTML.Form, required: true

  def pr_template(assigns) do
    ~H"""
    <.section_card label="PR template">
      <.form for={@form} id="project-pr-template-form" phx-submit="save_pr_template">
        <.input
          field={@form[:template]}
          type="textarea"
          label="Description"
          rows="8"
          spellcheck="false"
        />

        <p class="mb-4 text-[12px] leading-relaxed text-text3" phx-no-curly-interpolation>
          Used as the PR/MR description when Approve opens a pull request. Placeholders:
          <code class="font-mono">{{title}}</code>, <code class="font-mono">{{description}}</code>,
          <code class="font-mono">{{task_id}}</code>, and <code class="font-mono">{{branch}}</code>.
          Leave blank to fall back to the built-in default.
        </p>

        <div class="flex justify-end">
          <.button variant="primary" type="submit" phx-disable-with="Saving…">
            Save template
          </.button>
        </div>
      </.form>
    </.section_card>
    """
  end

  @doc """
  The linked git repositories. `base_clone_path` is managed by the finalizer
  and is shown as a state badge rather than offered as an input.
  """
  attr :repositories, :list, required: true
  attr :project_id, :integer, required: true

  def repositories(assigns) do
    ~H"""
    <.section_card label="Repositories">
      <:actions>
        <.button patch={~p"/settings/projects/#{@project_id}/repositories/new"}>
          Link repository
        </.button>
      </:actions>

      <div :if={@repositories == []}>
        <.empty_state icon="hero-code-bracket" title="No repository linked">
          Repo-targeted tasks need one. Content and design tasks can work in a task folder instead.
        </.empty_state>
      </div>

      <div id="repository-list">
        <.list_row
          :for={repository <- @repositories}
          id={"repository-row-#{repository.id}"}
          title={repository.name}
          subtitle={repository.git_url}
        >
          <:badges>
            <.badge variant={:neutral}>{repository.default_branch}</.badge>
            <.badge variant={if repository.base_clone_path, do: :ok, else: :neutral}>
              {if repository.base_clone_path, do: "Cloned", else: "Not cloned yet"}
            </.badge>
          </:badges>
          <:actions>
            <.button patch={~p"/settings/projects/#{@project_id}/repositories/#{repository.id}/edit"}>
              Edit
            </.button>
            <.delete_button
              id={"delete-repository-#{repository.id}"}
              value={repository.id}
              label="Unlink"
              reason={repository.delete_reason}
              confirm={"Unlink #{repository.name}? The clone on disk is left in place."}
            />
          </:actions>
        </.list_row>
      </div>
    </.section_card>
    """
  end

  @doc """
  The encrypted env store. Values are write-only — the list is built from
  keys alone so nothing is ever decrypted to render it.
  """
  attr :env_keys, :list, required: true
  attr :project_id, :integer, required: true

  def environment(assigns) do
    ~H"""
    <.section_card label="Environment">
      <:actions>
        <.button patch={~p"/settings/projects/#{@project_id}/env/new"}>Add variable</.button>
      </:actions>

      <p class="text-[12px] leading-relaxed text-text3">
        Injected into every agent process for this project. Encrypted at rest and write-only —
        a stored value is never shown again, only replaced.
      </p>

      <div :if={@env_keys == []}>
        <.empty_state icon="hero-key" title="No variables set">
          Forge tokens, API keys and build settings the agent's tooling needs.
        </.empty_state>
      </div>

      <div id="env-list">
        <.list_row
          :for={entry <- @env_keys}
          id={"env-row-#{entry.key}"}
          title={entry.key}
          subtitle={"Updated #{Format.relative(entry.updated_at)}"}
        >
          <:badges>
            <.badge :if={entry.forge_token?} variant={:accent}>git access</.badge>
          </:badges>
          <:meta>
            <.secret_value set?={true} />
          </:meta>
          <:actions>
            <.button patch={~p"/settings/projects/#{@project_id}/env/#{entry.key}/edit"}>
              Replace
            </.button>
            <.button
              id={"delete-env-#{entry.key}"}
              variant="danger"
              type="button"
              phx-click="delete_env"
              phx-value-key={entry.key}
              data-confirm={"Remove #{entry.key}? Runs that need it will fail."}
            >
              Remove
            </.button>
          </:actions>
        </.list_row>
      </div>
    </.section_card>
    """
  end

  @doc """
  The project's own agents — bound here specifically, not the shared org
  pool (those stay selectable in every project without appearing in this
  list). Creating and editing happens on the shared agents page; this tile
  only surveys and links there.
  """
  attr :project_agents, :list, required: true

  def agents(assigns) do
    ~H"""
    <.section_card label="Agents">
      <:actions>
        <.button navigate={~p"/settings/agents"}>Manage agents</.button>
      </:actions>

      <p class="text-[12px] leading-relaxed text-text3">
        Agents bound to this project only. Org-wide agents are also selectable
        here but are managed from Settings → Agents.
      </p>

      <div :if={@project_agents == []}>
        <.empty_state icon="hero-sparkles" title="No project-only agents">
          Bind an agent to this project from
          <.link navigate={~p"/settings/agents/new"} class="font-semibold text-accent">
            Settings → Agents
          </.link>
          .
        </.empty_state>
      </div>

      <div id="project-agent-list">
        <.list_row
          :for={agent <- @project_agents}
          id={"project-agent-row-#{agent.id}"}
          title={agent.name}
        >
          <:badges>
            <.badge variant={:accent}>{agent.work_type}</.badge>
            <.badge :for={role <- agent.roles} variant={:neutral}>{role}</.badge>
          </:badges>
          <:actions>
            <.button navigate={~p"/settings/agents/#{agent.id}/edit"}>Edit</.button>
          </:actions>
        </.list_row>
      </div>
    </.section_card>
    """
  end

  @doc """
  Default reviewers per work type. Saving replaces the set for that work
  type, so an empty submit clears it.
  """
  attr :reviewer_sets, :list, required: true

  def default_reviewers(assigns) do
    ~H"""
    <.section_card label="Default reviewers">
      <p class="text-[12px] leading-relaxed text-text3">
        Pre-fills the reviewer set on a new task of that work type. Still editable per task, and
        every verdict stays advisory.
      </p>

      <div class="flex flex-col gap-4">
        <div :for={set <- @reviewer_sets} class="flex flex-col gap-2">
          <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
            {work_type_label(set.work_type)}
          </span>

          <p :if={set.candidates == []} class="text-[12.5px] text-text3">
            No agent can review {set.work_type} work yet.
            <.link navigate={~p"/settings/agents/new"} class="font-semibold text-accent">
              Add a reviewer
            </.link>
          </p>

          <form
            :if={set.candidates != []}
            id={"default-reviewers-#{set.work_type}-form"}
            phx-submit="save_reviewers"
          >
            <input type="hidden" name="work_type" value={set.work_type} />
            <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
              <label
                :for={agent <- set.candidates}
                class="flex cursor-pointer items-center gap-2 text-[13px] text-text2"
              >
                <input
                  type="checkbox"
                  name="agent_ids[]"
                  value={agent.id}
                  checked={agent.id in set.selected_ids}
                  class="size-4 rounded border-border text-accent focus:ring-accent/40"
                />
                {agent.name}
              </label>
              <div class="ml-auto">
                <.button type="submit" phx-disable-with="Saving…">Save</.button>
              </div>
            </div>
          </form>
        </div>
      </div>
    </.section_card>
    """
  end

  defp work_type_label(work_type) do
    value = to_string(work_type)

    Enum.find_value(FormOptions.work_types(), value, fn {label, option} ->
      option == value && label
    end)
  end

  defp budget_hint(value) when value in [nil, ""], do: "No cost limit."

  defp budget_hint(value) do
    case value |> to_string() |> Integer.parse() do
      {cents, ""} when cents >= 0 -> "That's #{Format.cents(cents)}."
      _invalid -> "No cost limit."
    end
  end
end
