defmodule CodeLeadWeb.SettingsLive.Agents do
  @moduledoc """
  The pool of agent personas, org- and project-scoped alike. The form's
  project select drives `scope`: left on "All projects" the agent stays
  org-wide (selectable everywhere), picking a project binds it there only
  — see `CodeLead.Agents.eligible?/4`.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Agents
  alias CodeLead.Agents.Agent
  alias CodeLead.Projects
  alias CodeLeadWeb.FlashMessages
  alias CodeLeadWeb.FormOptions

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Agents",
       providers: Agents.list_providers(),
       projects: Projects.list_projects()
     )
     |> load_agents()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    {:noreply,
     socket
     |> assign(agent: %Agent{})
     |> assign_form(%Agent{}, %{
       "work_type" => "code",
       "driver" => "acp",
       "harness" => "claude_code",
       "roles" => "execute,review",
       "project_id" => ""
     })}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :edit}} = socket) do
    agent = Agents.get_agent!(id)

    {:noreply,
     socket
     |> assign(agent: agent)
     |> assign_form(agent, %{
       "name" => agent.name,
       "work_type" => to_string(agent.work_type),
       "driver" => to_string(agent.driver),
       "harness" => to_string(agent.harness),
       "roles" => FormOptions.role_value(agent.roles),
       "provider_id" => agent.provider_id,
       "model_variant" => agent.model_variant,
       "system_prompt" => agent.system_prompt,
       "project_id" => if(agent.project_id, do: to_string(agent.project_id), else: "")
     })}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, form: nil, agent: nil)}
  end

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    {:noreply, assign_form(socket, socket.assigns.agent, params)}
  end

  def handle_event("save", %{"agent" => params}, %{assigns: %{live_action: :new}} = socket) do
    case Agents.create_agent(agent_attrs(params)) do
      {:ok, agent} -> saved(socket, agent)
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset, as: "agent"))}
    end
  end

  def handle_event("save", %{"agent" => params}, socket) do
    case Agents.update_agent(socket.assigns.agent, agent_attrs(params)) do
      {:ok, agent} -> saved(socket, agent)
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset, as: "agent"))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case id |> Agents.get_agent!() |> Agents.delete_agent() do
      {:ok, agent} ->
        {:noreply, socket |> put_flash(:info, "#{agent.name} deleted.") |> load_agents()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.delete_error(reason))}
    end
  end

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="Agents" back={~p"/settings"}>
        <:actions>
          <.button
            :if={@providers != []}
            id="new-agent"
            variant="primary"
            patch={~p"/settings/agents/new"}
          >
            Add agent
          </.button>
        </:actions>
      </.settings_page_header>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto w-full max-w-4xl p-4 sm:p-6">
          <.section_card label="Agents">
            <div :if={@providers == []}>
              <.empty_state icon="hero-cloud" title="Connect a provider first">
                An agent needs a model backend.
                <.link navigate={~p"/settings/providers"} class="font-semibold text-accent">
                  Add a provider
                </.link>
                to get started.
              </.empty_state>
            </div>

            <div :if={@providers != [] and @agents == []}>
              <.empty_state icon="hero-sparkles" title="No agents yet">
                Nothing can run without an executor. Add your first persona.
              </.empty_state>
            </div>

            <div id="agent-list">
              <.list_row
                :for={agent <- @agents}
                id={"agent-row-#{agent.id}"}
                title={agent.name}
                subtitle={model_line(agent, @providers)}
              >
                <:badges>
                  <.badge variant={:accent}>{agent.work_type}</.badge>
                  <.badge :for={role <- agent.roles} variant={:neutral}>{role}</.badge>
                  <.badge variant={:run}>{driver_label(agent)}</.badge>
                  <.badge variant={:neutral}>{scope_label(agent, @projects)}</.badge>
                </:badges>
                <:actions>
                  <.button patch={~p"/settings/agents/#{agent.id}/edit"}>Edit</.button>
                  <.delete_button
                    id={"delete-agent-#{agent.id}"}
                    value={agent.id}
                    reason={usage_reason(agent.usage)}
                    confirm={"Delete #{agent.name}?"}
                  />
                </:actions>
              </.list_row>
            </div>
          </.section_card>
        </div>
      </div>

      <.modal
        :if={@live_action in [:new, :edit]}
        id="agent-modal"
        title={if @live_action == :new, do: "Add agent", else: "Edit agent"}
        return_to={~p"/settings/agents"}
      >
        <.form for={@form} id="agent-form" phx-change="validate" phx-submit="save">
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="Judy"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:project_id]}
            type="select"
            label="Project"
            options={FormOptions.project_options(@projects)}
          />
          <.input
            field={@form[:work_type]}
            type="select"
            label="Work type"
            options={FormOptions.work_types()}
          />
          <.input
            field={@form[:roles]}
            type="select"
            label="Can be slotted as"
            options={FormOptions.roles()}
            value={FormOptions.role_value(@form[:roles].value)}
          />
          <.input
            field={@form[:driver]}
            type="select"
            label="Driver"
            options={FormOptions.drivers()}
          />
          <.input
            :if={to_string(@form[:driver].value) in ["", "acp"]}
            field={@form[:harness]}
            type="select"
            label="Harness"
            options={FormOptions.harnesses()}
          />
          <.input
            field={@form[:provider_id]}
            type="select"
            label="Provider"
            options={FormOptions.provider_options(@providers)}
          />
          <.input field={@form[:model_variant]} label="Model" placeholder="claude-sonnet-5" />
          <.input
            field={@form[:system_prompt]}
            type="textarea"
            rows="4"
            label="System prompt"
            placeholder="You are a pragmatic senior engineer…"
          />

          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/settings/agents"}>Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Saving…">Save</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  ## Loading and forms

  defp load_agents(socket) do
    agents =
      Enum.map(Agents.list_all_agents(), fn agent ->
        Map.put(agent, :usage, Agents.agent_usage(agent.id))
      end)

    assign(socket, agents: agents)
  end

  defp assign_form(socket, agent, params) do
    changeset =
      (agent || %Agent{})
      |> Agents.change_agent(agent_attrs(params))
      |> Map.put(:action, :validate)

    assign(socket, form: to_form(changeset, as: "agent"))
  end

  # `roles` must become a list (an `{:array, Ecto.Enum}` cannot cast the
  # select's comma string) and `harness` must be nilled for `llm_api`, or a
  # stale value from a previous driver selection trips `validate_harness`.
  # `project_id` blank means org scope; a picked project derives `scope`
  # from it rather than the form carrying a separate scope input.
  defp agent_attrs(params) do
    driver = Map.get(params, "driver", "acp")
    project_id = params |> Map.get("project_id", "") |> blank_to_nil()

    params
    |> Map.put("roles", FormOptions.parse_roles(Map.get(params, "roles", "execute,review")))
    |> Map.put("harness", if(driver == "acp", do: Map.get(params, "harness")))
    |> Map.put("project_id", project_id)
    |> Map.put("scope", if(project_id, do: "project", else: "org"))
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp saved(socket, agent) do
    {:noreply,
     socket
     |> put_flash(:info, "#{agent.name} saved.")
     |> push_patch(to: ~p"/settings/agents")
     |> load_agents()}
  end

  ## Row copy

  defp driver_label(%{driver: :acp, harness: harness}), do: "acp · #{harness}"
  defp driver_label(%{driver: driver}), do: to_string(driver)

  defp scope_label(%{scope: :org}, _projects), do: "All projects"

  defp scope_label(%{scope: :project, project_id: project_id}, projects) do
    Enum.find_value(projects, "Unknown project", &(&1.id == project_id && &1.name))
  end

  defp model_line(%{provider_id: provider_id, model_variant: variant}, providers) do
    name =
      Enum.find_value(providers, "unknown provider", fn p -> p.id == provider_id && p.name end)

    if variant in [nil, ""], do: name, else: "#{name} · #{variant}"
  end

  defp usage_reason(%{tasks: 0, reviewer_slots: 0, default_reviewer_slots: 0}), do: nil

  defp usage_reason(usage),
    do: FlashMessages.delete_error({:in_use, usage})
end
