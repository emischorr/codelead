defmodule CodeLeadWeb.SetupLive do
  @moduledoc """
  The first-run wizard: organization + admin, a provider, and optionally a
  project (with a repository) and a first agent.

  Every step commits to the database as soon as it is submitted, so the
  current step is *derived* from what already exists rather than tracked as
  navigation state — a reload mid-wizard resumes where it left off. Skipping
  an optional step is the only per-session decision, held in `:skipped`.
  """

  use CodeLeadWeb, :live_view

  alias CodeLead.Accounts
  alias CodeLead.Agents
  alias CodeLead.Agents.Provider
  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLeadWeb.FormOptions
  alias CodeLeadWeb.SetupLive.Steps

  @steps [
    %{id: :admin, label: "Admin", hint: "Name the instance and create your login"},
    %{id: :provider, label: "Provider", hint: "Connect the backend your agents talk to"},
    %{id: :project, label: "Project", hint: "A product workspace and its repository"},
    %{id: :agent, label: "Agent", hint: "The first worker persona"},
    %{id: :finish, label: "Finish", hint: "Open CodeLead"}
  ]

  @access_check_timeout :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Setup", skipped: MapSet.new(), trigger_submit: false)
      |> assign(organization_name: "CodeLead")
      |> assign_admin_form(%{})
      |> assign_provider_form(%{"name" => "Anthropic", "kind" => "anthropic_api"})
      |> assign_project_form(%{"default_branch" => "main"})
      |> assign_agent_form(%{
        "work_type" => "code",
        "driver" => "acp",
        "harness" => "claude_code"
      })
      |> load_state()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} width="max-w-2xl">
      <div class="mb-6">
        <h1 class="text-[22px] font-bold tracking-tight text-text">Set up CodeLead</h1>
        <p class="mt-1 text-[13.5px] text-text2">
          A few minutes to a working instance. Nothing leaves this machine.
        </p>
      </div>

      <ol id="setup-steps" class="mb-5 flex flex-wrap items-center gap-x-2 gap-y-2">
        <li :for={{step, index} <- Enum.with_index(@steps, 1)} class="flex items-center gap-2">
          <span class={[
            "flex size-[22px] shrink-0 items-center justify-center rounded-full font-mono text-[11px] font-semibold",
            step_state(step.id, @step, @steps) == :done && "bg-ok-soft text-ok",
            step_state(step.id, @step, @steps) == :current && "bg-accent text-white",
            step_state(step.id, @step, @steps) == :todo && "bg-surface2 text-text3"
          ]}>
            {index}
          </span>
          <span class={[
            "text-[12.5px]",
            step.id == @step && "font-semibold text-text",
            step.id != @step && "text-text3"
          ]}>
            {step.label}
          </span>
          <span :if={index < length(@steps)} class="ml-1 h-px w-4 bg-border" />
        </li>
      </ol>

      <div class="rounded-2xl border border-border bg-surface p-6 shadow-sm sm:p-7">
        <h2 class="text-[16px] font-bold tracking-tight text-text">{current_step(@step).label}</h2>
        <p class="mt-1 mb-5 text-[13px] text-text2">{current_step(@step).hint}</p>

        <Steps.admin
          :if={@step == :admin}
          form={@admin_form}
          organization_name={@organization_name}
          trigger_submit={@trigger_submit}
        />
        <Steps.provider :if={@step == :provider} form={@provider_form} />
        <Steps.project :if={@step == :project} form={@project_form} />
        <Steps.agent :if={@step == :agent} form={@agent_form} providers={@providers} />
        <Steps.finish
          :if={@step == :finish}
          admin_username={@admin_username}
          providers={@providers}
          projects={@projects}
          agents?={@agents?}
        />
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def handle_event("validate_admin", %{"user" => user_params} = params, socket) do
    {:noreply,
     socket
     |> assign_admin_form(user_params)
     |> assign(organization_name: organization_name(params))}
  end

  def handle_event("submit_admin", %{"user" => user_params} = params, socket) do
    changeset = Accounts.change_admin_registration(user_params)

    if changeset.valid? do
      {:noreply, assign(socket, trigger_submit: true)}
    else
      {:noreply,
       socket
       |> assign_admin_form(user_params)
       |> assign(organization_name: organization_name(params))}
    end
  end

  def handle_event("create_provider", %{"provider" => params}, socket) do
    attrs = %{
      name: Map.get(params, "name"),
      kind: Map.get(params, "kind", "anthropic_api"),
      credential: Map.get(params, "credential", "")
    }

    case Agents.save_provider(%Provider{}, attrs) do
      {:ok, _provider} ->
        {:noreply, socket |> put_flash(:info, "Provider connected.") |> load_state()}

      {:error, changeset} ->
        errors = changeset |> changeset_errors() |> rename_error(:config, :credential)
        {:noreply, assign_provider_form(socket, params, errors)}
    end
  end

  def handle_event("validate_provider", %{"provider" => params}, socket) do
    {:noreply, assign_provider_form(socket, params)}
  end

  def handle_event("create_project", %{"project" => params}, socket) do
    project_attrs = %{name: Map.get(params, "name")}

    case Projects.create_project_with_repository(project_attrs, repository_attrs(params)) do
      {:ok, project} ->
        {kind, message} =
          case store_access_token(project.id, params) do
            :ok -> {:info, "Project created."}
            {:error, detail} -> {:error, "Project created, but #{detail}"}
          end

        {:noreply, socket |> put_flash(kind, message) |> load_state()}

      {:error, :project, changeset} ->
        {:noreply, assign_project_form(socket, params, changeset_errors(changeset))}

      {:error, :repository, changeset} ->
        errors = changeset |> changeset_errors() |> rename_error(:name, :repo_name)
        {:noreply, assign_project_form(socket, params, errors)}
    end
  end

  def handle_event("create_agent", %{"agent" => params}, socket) do
    driver = Map.get(params, "driver", "acp")

    attrs = %{
      name: Map.get(params, "name"),
      scope: :org,
      roles: FormOptions.parse_roles(Map.get(params, "roles", "execute,review")),
      work_type: Map.get(params, "work_type"),
      driver: driver,
      harness: if(driver == "acp", do: Map.get(params, "harness")),
      provider_id: Map.get(params, "provider_id"),
      model_variant: Map.get(params, "model_variant"),
      system_prompt: Map.get(params, "system_prompt")
    }

    case Agents.create_agent(attrs) do
      {:ok, _agent} ->
        {:noreply, socket |> put_flash(:info, "Agent created.") |> load_state()}

      {:error, changeset} ->
        {:noreply, assign_agent_form(socket, params, changeset_errors(changeset))}
    end
  end

  def handle_event("validate_agent", %{"agent" => params}, socket) do
    {:noreply, assign_agent_form(socket, params)}
  end

  def handle_event("skip", %{"step" => step}, socket) when step in ~w(project agent) do
    skipped = MapSet.put(socket.assigns.skipped, skippable_step(step))
    {:noreply, socket |> assign(skipped: skipped) |> load_state()}
  end

  def handle_event("finish", _params, socket) do
    {:ok, _organization} = Accounts.complete_setup()

    {:noreply,
     socket
     |> put_flash(:info, "CodeLead is ready.")
     |> push_navigate(to: ~p"/")}
  end

  ## Step derivation

  defp load_state(socket) do
    providers = Agents.list_providers()
    projects = Projects.list_projects()
    agents? = Agents.any_agents?()
    skipped = socket.assigns.skipped

    step =
      cond do
        not Accounts.any_users?() -> :admin
        providers == [] -> :provider
        projects == [] and not MapSet.member?(skipped, :project) -> :project
        not agents? and not MapSet.member?(skipped, :agent) -> :agent
        true -> :finish
      end

    assign(socket,
      steps: @steps,
      step: step,
      providers: providers,
      projects: projects,
      agents?: agents?,
      admin_username: admin_username()
    )
  end

  defp admin_username do
    case Accounts.list_users() do
      [user | _rest] -> user.username
      [] -> nil
    end
  end

  defp current_step(step), do: Enum.find(@steps, &(&1.id == step))

  defp step_state(step, step, _steps), do: :current

  defp step_state(candidate, current, steps) do
    index = Enum.find_index(steps, &(&1.id == candidate))
    current_index = Enum.find_index(steps, &(&1.id == current))
    if index < current_index, do: :done, else: :todo
  end

  defp skippable_step("project"), do: :project
  defp skippable_step("agent"), do: :agent

  ## Forms

  defp assign_admin_form(socket, params) do
    changeset = params |> Accounts.change_admin_registration() |> Map.put(:action, :validate)
    assign(socket, admin_form: to_form(changeset, as: "user"))
  end

  defp assign_provider_form(socket, params, errors \\ []) do
    assign(socket, provider_form: to_form(params, as: "provider", errors: errors))
  end

  defp assign_project_form(socket, params, errors \\ []) do
    assign(socket, project_form: to_form(params, as: "project", errors: errors))
  end

  defp assign_agent_form(socket, params, errors \\ []) do
    assign(socket, agent_form: to_form(params, as: "agent", errors: errors))
  end

  # Linking a repository is optional: a blank git URL creates the project alone.
  defp repository_attrs(params) do
    git_url = params |> Map.get("git_url", "") |> String.trim()

    if git_url == "" do
      nil
    else
      %{
        name: params |> Map.get("repo_name", "") |> String.trim(),
        git_url: git_url,
        default_branch: Map.get(params, "default_branch", "main")
      }
    end
  end

  # The token is not a repository attribute — it lives in the encrypted
  # project env store under the key the git plumbing and the finalizer
  # both read. The project row is already committed by the time we get
  # here, so a token the forge rejects is reported, not fatal.
  defp store_access_token(project_id, params) do
    token = params |> Map.get("access_token", "") |> String.trim()
    git_url = params |> Map.get("git_url", "") |> String.trim()

    case {token, Git.forge(git_url)} do
      {"", _forge} ->
        :ok

      {_token, :other} ->
        :ok

      {token, {kind, _owner, _repo}} ->
        {:ok, _env} = Projects.put_env(project_id, Git.token_var(kind), token)
        verify_access(git_url, token, Git.token_var(kind), Git.host(kind))
    end
  end

  # A bad token is far cheaper to diagnose here than at dispatch, three
  # screens later. `ls-remote` can't prompt (git runs with terminal
  # prompts disabled) but it can hang on the network, so it is bounded.
  defp verify_access(git_url, token, token_var, host) do
    {module, function} = Application.get_env(:code_lead, :git_access_check)
    task = Task.async(fn -> apply(module, function, [git_url, [token: token]]) end)

    case Task.yield(task, @access_check_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, output}} ->
        detail = output |> Git.failure_reason() |> Git.redact()
        {:error, "#{host} rejected the #{token_var}: #{detail}"}

      _timeout ->
        {:error, "the #{token_var} could not be verified — #{host} did not answer in time."}
    end
  end

  defp changeset_errors(%Ecto.Changeset{errors: errors}), do: errors

  defp rename_error(errors, from, to) do
    Enum.map(errors, fn
      {^from, error} -> {to, error}
      other -> other
    end)
  end

  defp organization_name(params) do
    params |> get_in(["organization", "name"]) |> to_string()
  end
end
