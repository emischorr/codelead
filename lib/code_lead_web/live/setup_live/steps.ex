defmodule CodeLeadWeb.SetupLive.Steps do
  @moduledoc """
  The panels of the first-run wizard. Presentation only — every event is
  handled by `CodeLeadWeb.SetupLive`.
  """

  use CodeLeadWeb, :html

  alias CodeLeadWeb.FormOptions

  @doc """
  Organization name plus the admin login. Submits over HTTP so the session
  can be written — see `CodeLeadWeb.SetupController`.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :organization_name, :string, required: true
  attr :trigger_submit, :boolean, required: true

  def admin(assigns) do
    ~H"""
    <.form
      for={@form}
      id="setup-admin-form"
      action={~p"/setup/admin"}
      phx-change="validate_admin"
      phx-submit="submit_admin"
      phx-trigger-action={@trigger_submit}
    >
      <.input
        id="setup-organization-name"
        name="organization[name]"
        value={@organization_name}
        label="Organization name"
        required
      />
      <.input
        field={@form[:username]}
        type="text"
        label="Your username"
        autocomplete="username"
        spellcheck="false"
        required
        phx-mounted={JS.focus()}
      />
      <.input
        field={@form[:email]}
        type="email"
        label="Your email (optional)"
        autocomplete="email"
        spellcheck="false"
      />
      <.input
        field={@form[:password]}
        type="password"
        label="Password"
        autocomplete="new-password"
        spellcheck="false"
        required
      />
      <p class="mb-4 text-[12px] text-text3">At least 12 characters.</p>

      <.button variant="primary" full phx-disable-with="Creating…">
        Create admin and continue
      </.button>
    </.form>
    """
  end

  @doc """
  The model backend the agents talk to. Credentials are encrypted at rest.
  """
  attr :form, Phoenix.HTML.Form, required: true

  def provider(assigns) do
    ~H"""
    <.form
      for={@form}
      id="setup-provider-form"
      phx-change="validate_provider"
      phx-submit="create_provider"
    >
      <.input
        field={@form[:name]}
        label="Display name"
        autocomplete="off"
        required
        phx-mounted={JS.focus()}
      />
      <.input field={@form[:kind]} type="select" label="Backend" options={provider_kinds()} />
      <.input
        field={@form[:credential]}
        type={credential_type(@form[:kind].value)}
        label={credential_label(@form[:kind].value)}
        placeholder={credential_placeholder(@form[:kind].value)}
        autocomplete="new-password"
        data-1p-ignore="true"
        data-lpignore="true"
        data-bwignore="true"
        spellcheck="false"
        required
      />
      <p class="mb-4 text-[12px] text-text3">
        Stored encrypted with this instance's <code class="font-mono">ENCRYPTION_KEY</code>.
      </p>

      <.button variant="primary" full phx-disable-with="Connecting…">
        Connect provider and continue
      </.button>
    </.form>
    """
  end

  @doc """
  A product workspace and, optionally, its first repository. Skippable.
  """
  attr :form, Phoenix.HTML.Form, required: true

  def project(assigns) do
    ~H"""
    <.form for={@form} id="setup-project-form" phx-submit="create_project">
      <.input field={@form[:name]} label="Project name" required phx-mounted={JS.focus()} />

      <div class="my-5 h-px bg-border" />

      <p class="mb-3 text-[11px] font-semibold uppercase tracking-wider text-text3">
        Repository — optional
      </p>
      <.input field={@form[:repo_name]} label="Repository name" placeholder="my-app" />
      <.input
        field={@form[:git_url]}
        label="Git URL"
        placeholder="git@github.com:me/my-app.git"
        spellcheck="false"
      />
      <.input field={@form[:default_branch]} label="Default branch" />
      <.input
        field={@form[:access_token]}
        type="password"
        label="Access token — optional"
        placeholder="github_pat_…"
        autocomplete="new-password"
        data-1p-ignore="true"
        data-lpignore="true"
        data-bwignore="true"
      />
      <p class="-mt-2 mb-4 text-[12px] leading-relaxed text-text3">
        Needed for private GitHub or GitLab repositories over <code>https://</code>. Stored
        encrypted with this instance's <code>ENCRYPTION_KEY</code>. SSH URLs use this
        machine's key instead and need no token.
      </p>

      <.button variant="primary" full phx-disable-with="Creating…">
        Create project and continue
      </.button>
    </.form>

    <.skip_link step="project" label="Skip — I'll add a project later" />
    """
  end

  @doc """
  The first worker persona. Skippable, but nothing can run without one.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :providers, :list, required: true

  def agent(assigns) do
    ~H"""
    <.form for={@form} id="setup-agent-form" phx-change="validate_agent" phx-submit="create_agent">
      <.input field={@form[:name]} label="Name" placeholder="Judy" required phx-mounted={JS.focus()} />
      <.input field={@form[:work_type]} type="select" label="Work type" options={work_types()} />
      <.input field={@form[:roles]} type="select" label="Can be slotted as" options={roles()} />
      <.input field={@form[:driver]} type="select" label="Driver" options={drivers()} />
      <.input
        :if={@form[:driver].value in [nil, "acp"]}
        field={@form[:harness]}
        type="select"
        label="Harness"
        options={harnesses()}
      />
      <.input
        field={@form[:provider_id]}
        type="select"
        label="Provider"
        options={provider_options(@providers)}
      />
      <.input field={@form[:model_variant]} label="Model" placeholder="claude-sonnet-5" />
      <.input
        field={@form[:system_prompt]}
        type="textarea"
        rows="4"
        label="System prompt"
        placeholder="You are a pragmatic senior engineer…"
      />

      <.button variant="primary" full phx-disable-with="Creating…">
        Create agent and continue
      </.button>
    </.form>

    <.skip_link step="agent" label="Skip — I'll add an agent later" />
    """
  end

  @doc """
  Recap of what the wizard created, and the button that flips `setup_done`.
  """
  attr :admin_username, :string, default: nil
  attr :providers, :list, required: true
  attr :projects, :list, required: true
  attr :agents?, :boolean, required: true

  def finish(assigns) do
    ~H"""
    <ul class="mb-6 flex flex-col gap-2.5">
      <.recap done label="Admin" detail={@admin_username} />
      <.recap done label="Provider" detail={Enum.map_join(@providers, ", ", & &1.name)} />
      <.recap
        done={@projects != []}
        label="Project"
        detail={if @projects == [], do: "skipped", else: Enum.map_join(@projects, ", ", & &1.name)}
      />
      <.recap done={@agents?} label="Agent" detail={if @agents?, do: "ready", else: "skipped"} />
    </ul>

    <p :if={@projects == [] or not @agents?} class="mb-5 text-[12.5px] text-text2">
      You can add what you skipped later — a task needs a project and an executor agent before it
      can run.
    </p>

    <.button id="setup-finish" variant="primary" full phx-click="finish" phx-disable-with="Opening…">
      Finish setup
    </.button>
    """
  end

  attr :done, :boolean, default: false
  attr :label, :string, required: true
  attr :detail, :string, default: nil

  defp recap(assigns) do
    ~H"""
    <li class="flex items-center gap-2.5 text-[13px]">
      <.icon
        name={if @done, do: "hero-check-circle", else: "hero-minus-circle"}
        class={["size-4 shrink-0", if(@done, do: "text-ok", else: "text-text3")]}
      />
      <span class="font-semibold text-text">{@label}</span>
      <span :if={@detail not in [nil, ""]} class="truncate text-text3">{@detail}</span>
    </li>
    """
  end

  attr :step, :string, required: true
  attr :label, :string, required: true

  defp skip_link(assigns) do
    ~H"""
    <button
      id={"setup-skip-#{@step}"}
      type="button"
      class="mt-4 w-full cursor-pointer text-center text-[12.5px] font-medium text-text3 hover:text-text2"
      phx-click="skip"
      phx-value-step={@step}
    >
      {@label}
    </button>
    """
  end

  defp provider_options(providers), do: FormOptions.provider_options(providers)
  defp provider_kinds, do: FormOptions.provider_kinds()
  defp work_types, do: FormOptions.work_types()
  defp roles, do: FormOptions.roles()
  defp drivers, do: FormOptions.drivers()
  defp harnesses, do: FormOptions.harnesses()
  defp credential_type(kind), do: FormOptions.credential_type(kind)
  defp credential_label(kind), do: FormOptions.credential_label(kind)
  defp credential_placeholder(kind), do: FormOptions.credential_placeholder(kind)
end
