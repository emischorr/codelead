defmodule CodeLeadWeb.SettingsLive.Organization do
  @moduledoc """
  Instance-wide organization settings, admin-only: the name, the org
  budget limits, and the default project budget limits that are copied
  onto each new project at creation.

  Writes go through `Accounts.update_organization/2`, whose changeset
  never casts `settings` — the `"setup_done"` flag cannot be clobbered
  from here.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Accounts

  @budget_keys ~w(budget_limit_cents budget_limit_tokens
                  default_project_budget_limit_cents default_project_budget_limit_tokens)

  @impl true
  def mount(_params, _session, socket) do
    organization = Accounts.get_organization!()

    {:ok,
     socket
     |> assign(page_title: "Organization", organization: organization)
     |> assign_form(%{})}
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    case Accounts.update_organization(socket.assigns.current_scope, blank_to_nil(params)) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(organization: organization)
         |> assign_form(%{})
         |> put_flash(:info, "Organization settings saved.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Administrator access required.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="Organization" back={~p"/settings"} />

      <div class="min-h-0 flex-1 overflow-y-auto p-4 sm:p-5">
        <div class="mx-auto flex w-full max-w-2xl flex-col gap-3.5">
          <.section_card label="Organization">
            <.form
              for={@form}
              id="organization-form"
              phx-change="validate"
              phx-submit="save"
              class="flex flex-col"
            >
              <.input field={@form[:name]} type="text" label="Name" />

              <div class="mt-2 grid gap-x-3 sm:grid-cols-2">
                <.input
                  field={@form[:budget_limit_cents]}
                  type="number"
                  min="0"
                  label="Monthly cost limit (cents)"
                  placeholder="No limit"
                />
                <.input
                  field={@form[:budget_limit_tokens]}
                  type="number"
                  min="0"
                  label="Monthly token limit"
                  placeholder="No limit"
                />
              </div>

              <p class="mb-4 text-[12px] leading-relaxed text-text3">
                The organization-wide backstop: limits cover the current calendar month (UTC)
                and reset on the 1st. A run that would push the instance past one is held in
                the queue rather than started. Leave blank for no limit.
              </p>

              <div class="mt-1 grid gap-x-3 sm:grid-cols-2">
                <.input
                  field={@form[:default_project_budget_limit_cents]}
                  type="number"
                  min="0"
                  label="Default project cost limit (cents)"
                  placeholder="No limit"
                />
                <.input
                  field={@form[:default_project_budget_limit_tokens]}
                  type="number"
                  min="0"
                  label="Default project token limit"
                  placeholder="No limit"
                />
              </div>

              <p class="mb-4 text-[12px] leading-relaxed text-text3">
                Copied onto each new project at creation; existing projects are not affected.
                Administrators can adjust any project's own limits afterwards.
              </p>

              <div>
                <.button id="save-organization" variant="primary" type="submit">
                  Save
                </.button>
              </div>
            </.form>
          </.section_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Internals

  defp assign_form(socket, params) do
    changeset =
      socket.assigns.organization
      |> CodeLead.Accounts.Organization.details_changeset(blank_to_nil(params))
      |> Map.put(:action, if(params == %{}, do: nil, else: :validate))

    assign(socket, form: to_form(changeset))
  end

  # An empty number input arrives as "", which would fail the integer
  # cast rather than clearing the limit.
  defp blank_to_nil(params) do
    Map.new(params, fn
      {key, ""} when key in @budget_keys -> {key, nil}
      pair -> pair
    end)
  end
end
