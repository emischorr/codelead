defmodule CodeLeadWeb.SettingsLive.Providers do
  @moduledoc """
  Model backends and their encrypted credentials.

  The form is params-backed rather than changeset-backed on purpose:
  `credential` is not a schema field, and `providers.config` decrypts on load,
  so the stored secret must never reach an assign. The list works from a
  reduced summary that carries only whether a credential is set.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Agents
  alias CodeLead.Agents.Provider
  alias CodeLeadWeb.FlashMessages
  alias CodeLeadWeb.FormOptions

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Providers") |> load_providers()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    {:noreply,
     socket
     |> assign(provider: %Provider{})
     |> assign_form(%{"name" => "", "kind" => "anthropic_api", "credential" => ""})}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :edit}} = socket) do
    provider = Agents.get_provider!(id)

    {:noreply,
     socket
     |> assign(provider: provider)
     |> assign_form(%{
       "name" => provider.name,
       "kind" => to_string(provider.kind),
       "credential" => ""
     })}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, form: nil, provider: nil)}
  end

  @impl true
  def handle_event("validate", %{"provider" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("save", %{"provider" => params}, socket) do
    attrs = %{
      name: Map.get(params, "name"),
      kind: Map.get(params, "kind", "anthropic_api"),
      credential: Map.get(params, "credential", "")
    }

    case Agents.save_provider(socket.assigns.provider, attrs) do
      {:ok, provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{provider.name} saved.")
         |> push_patch(to: ~p"/settings/providers")
         |> load_providers()}

      {:error, changeset} ->
        errors = changeset.errors |> rename_error(:config, :credential)
        {:noreply, assign_form(socket, params, errors)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case id |> Agents.get_provider!() |> Agents.delete_provider() do
      {:ok, provider} ->
        {:noreply, socket |> put_flash(:info, "#{provider.name} deleted.") |> load_providers()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.delete_error(reason))}
    end
  end

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="Providers" back={~p"/settings"}>
        <:actions>
          <.button id="new-provider" variant="primary" patch={~p"/settings/providers/new"}>
            Add provider
          </.button>
        </:actions>
      </.settings_page_header>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto w-full max-w-4xl p-4 sm:p-6">
          <.section_card label="Model backends">
            <div :if={@providers == []}>
              <.empty_state icon="hero-cloud" title="No provider connected">
                Agents need a backend to talk to. Add one to get anything running.
              </.empty_state>
            </div>

            <div id="provider-list">
              <.list_row
                :for={provider <- @providers}
                id={"provider-row-#{provider.id}"}
                title={provider.name}
                subtitle={provider.endpoint}
              >
                <:badges>
                  <.badge variant={:neutral}>{FormOptions.provider_kind_label(provider.kind)}</.badge>
                </:badges>
                <:meta>
                  <.secret_value :if={provider.secret?} set?={provider.credential_set?} />
                  <.badge :if={!provider.secret? and !provider.credential_set?} variant={:warn}>
                    No endpoint
                  </.badge>
                </:meta>
                <:actions>
                  <.button patch={~p"/settings/providers/#{provider.id}/edit"}>Edit</.button>
                  <.delete_button
                    id={"delete-provider-#{provider.id}"}
                    value={provider.id}
                    reason={usage_reason(provider.used_by)}
                    confirm={"Delete #{provider.name}? Its stored credential is destroyed."}
                  />
                </:actions>
              </.list_row>
            </div>
          </.section_card>
        </div>
      </div>

      <.modal
        :if={@live_action in [:new, :edit]}
        id="provider-modal"
        title={if @live_action == :new, do: "Add provider", else: "Edit provider"}
        return_to={~p"/settings/providers"}
      >
        <.form for={@form} id="provider-form" phx-change="validate" phx-submit="save">
          <.input
            field={@form[:name]}
            label="Display name"
            autocomplete="off"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:kind]}
            type="select"
            label="Backend"
            options={FormOptions.provider_kinds()}
          />
          <.input
            field={@form[:credential]}
            type={FormOptions.credential_type(@form[:kind].value)}
            label={FormOptions.credential_label(@form[:kind].value)}
            placeholder={credential_placeholder(@live_action, @form[:kind].value)}
            autocomplete="new-password"
            data-1p-ignore="true"
            data-lpignore="true"
            data-bwignore="true"
            spellcheck="false"
            required={@live_action == :new}
          />
          <p :if={kind_changed?(@provider, @form[:kind].value)} class="mb-4 text-[12px] text-warn">
            A different backend stores its credential under a different key — enter a new one.
          </p>
          <p
            :if={@live_action == :edit and not kind_changed?(@provider, @form[:kind].value)}
            class="mb-4 text-[12px] text-text3"
          >
            Leave blank to keep the stored credential. It is never sent to the browser.
          </p>
          <p :if={@live_action == :new} class="mb-4 text-[12px] text-text3">
            Stored encrypted with this instance's <code class="font-mono">ENCRYPTION_KEY</code>.
          </p>

          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/settings/providers"}>Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Saving…">Save</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  ## Loading

  # Providers are reduced to a summary before they reach an assign: `config`
  # is decrypted on load, so keeping the struct around would park live
  # secrets in the socket.
  defp load_providers(socket) do
    providers =
      Enum.map(Agents.list_providers(), fn provider ->
        key = Agents.credential_key(provider.kind)
        secret? = FormOptions.secret_credential?(provider.kind)
        credential = Map.get(provider.config || %{}, key)

        %{
          id: provider.id,
          name: provider.name,
          kind: provider.kind,
          secret?: secret?,
          credential_set?: credential not in [nil, ""],
          endpoint: if(not secret?, do: credential),
          used_by: Agents.provider_usage(provider.id)
        }
      end)

    assign(socket, providers: providers)
  end

  defp assign_form(socket, params, errors \\ []) do
    assign(socket, form: to_form(params, as: "provider", errors: errors))
  end

  ## Copy

  defp usage_reason([]), do: nil

  defp usage_reason(names),
    do: "Used by #{Enum.join(names, ", ")}. Point those agents elsewhere first."

  defp kind_changed?(%Provider{id: id, kind: kind}, selected) when not is_nil(id),
    do: to_string(kind) != to_string(selected)

  defp kind_changed?(_provider, _selected), do: false

  defp credential_placeholder(:edit, _kind), do: "Leave blank to keep the stored credential"
  defp credential_placeholder(_action, kind), do: FormOptions.credential_placeholder(kind)

  defp rename_error(errors, from, to) do
    Enum.map(errors, fn
      {^from, error} -> {to, error}
      other -> other
    end)
  end
end
