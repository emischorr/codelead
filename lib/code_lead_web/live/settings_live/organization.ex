defmodule CodeLeadWeb.SettingsLive.Organization do
  @moduledoc """
  Instance-wide organization settings, admin-only: the name, the org
  budget limits, the default project budget limits that are copied onto
  each new project at creation, and the org env store — merged live into
  every project's own env vars (see `CodeLead.Projects.env_vars/1`), in
  contrast to the budgets above which are copied once and never again.

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
     |> assign_form(%{})
     |> load_env_keys()}
  end

  @impl true
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
    {:noreply, assign(socket, env_form: nil, env_key: nil)}
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

  ## Env store

  def handle_event("validate_env", %{"env" => params}, socket) do
    {:noreply, assign_env_form(socket, socket.assigns.env_key, params)}
  end

  def handle_event("save_env", %{"env" => params}, socket) do
    key = params |> Map.get("key", "") |> String.trim()
    value = Map.get(params, "value", "")
    secret = Map.get(params, "secret", "true") == "true"

    case Accounts.put_org_env(socket.assigns.current_scope, key, value, secret) do
      {:ok, _env} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{key} saved.")
         |> push_patch(to: ~p"/settings/organization")
         |> load_env_keys()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Administrator access required.")}

      {:error, changeset} ->
        {:noreply, assign_env_form(socket, socket.assigns.env_key, params, changeset.errors)}
    end
  end

  def handle_event("delete_env", %{"key" => key}, socket) do
    case Accounts.delete_org_env(socket.assigns.current_scope, key) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "#{key} removed.") |> load_env_keys()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Administrator access required.")}
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

          <.section_card label="Environment">
            <:actions>
              <.button patch={~p"/settings/organization/env/new"}>Add variable</.button>
            </:actions>

            <p class="text-[12px] leading-relaxed text-text3">
              Injected into every agent process on every project. A project can define its own
              entry with the same name to override this value — see that project's settings.
            </p>

            <div :if={@env_keys == []}>
              <.empty_state icon="hero-key" title="No variables set">
                Forge tokens, API keys and build settings shared by every project.
              </.empty_state>
            </div>

            <div id="env-list">
              <.list_row
                :for={entry <- @env_keys}
                id={"env-row-#{entry.key}"}
                title={entry.key}
                subtitle={"Updated #{Format.relative(entry.updated_at)}"}
              >
                <:meta>
                  <.secret_value :if={entry.secret} set?={true} />
                  <span :if={!entry.secret} class="font-mono text-[12px] text-text2">
                    {entry.value}
                  </span>
                </:meta>
                <:actions>
                  <.button patch={~p"/settings/organization/env/#{entry.key}/edit"}>
                    {if entry.secret, do: "Replace", else: "Edit"}
                  </.button>
                  <.button
                    id={"delete-env-#{entry.key}"}
                    variant="danger"
                    type="button"
                    phx-click="delete_env"
                    phx-value-key={entry.key}
                    data-confirm={"Remove #{entry.key}? Projects relying on it will fail."}
                  >
                    Remove
                  </.button>
                </:actions>
              </.list_row>
            </div>
          </.section_card>
        </div>
      </div>

      <.modal
        :if={@live_action in [:new_env, :edit_env]}
        id="env-modal"
        title={if @live_action == :new_env, do: "Add variable", else: "Edit variable"}
        return_to={~p"/settings/organization"}
      >
        <.form for={@env_form} id="env-form" phx-change="validate_env" phx-submit="save_env">
          <.env_form_fields form={@env_form} new?={@live_action == :new_env} />

          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/settings/organization"}>Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Saving…">Save</.button>
          </div>
        </.form>
      </.modal>
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

  defp load_env_keys(socket) do
    assign(socket, env_keys: Accounts.list_org_env_keys())
  end

  defp assign_env_form(socket, key, params, errors \\ []) do
    socket
    |> assign(env_key: key)
    |> assign(env_form: to_form(params, as: "env", errors: errors))
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
