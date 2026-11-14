defmodule FrontSeatWeb.UserLive.Settings.NewToken do
  @moduledoc """
  Mints a personal access token, gated by sudo mode — a hijacked session
  must not be able to turn itself into a long-lived credential. The same
  per-action split as `UserLive.Settings.Email`/`Password`: the list and
  revoke page (`UserLive.Settings.Tokens`) is not gated.

  The plaintext is held only in this LiveView's assigns after creation and
  rendered once; navigating away loses it for good.
  """

  use FrontSeatWeb, :live_view

  on_mount {FrontSeatWeb.UserAuth, :require_sudo_mode}

  import FrontSeatWeb.SettingsLive.Components

  alias FrontSeat.Accounts
  alias FrontSeat.Accounts.ApiToken
  alias FrontSeat.License

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="New API token" back={~p"/users/settings/tokens"} />

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto flex w-full max-w-2xl flex-col gap-3.5 p-4 sm:p-6">
          <%= cond do %>
            <% @plaintext -> %>
              <.section_card label="Your new token" id="token-created">
                <p class="mb-3 text-[13px] leading-relaxed text-text2">
                  Copy it now. This is the only time it is shown — FrontSeat stores only a hash.
                </p>
                <div class="flex items-center gap-2">
                  <code
                    id="token-plaintext"
                    class="min-w-0 flex-1 select-all break-all rounded-lg border border-border bg-surface2 px-3 py-2 font-mono text-[12.5px] text-text"
                  >
                    {@plaintext}
                  </code>
                  <.button
                    id="copy-token"
                    type="button"
                    phx-hook=".CopyToken"
                    data-target="token-plaintext"
                  >
                    <.icon name="hero-clipboard-document" class="size-4" /> Copy
                  </.button>
                </div>
                <div class="mt-4 flex justify-end">
                  <.button id="token-done" variant="primary" navigate={~p"/users/settings/tokens"}>
                    Done
                  </.button>
                </div>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToken">
                  export default {
                    mounted() {
                      this.el.addEventListener("click", () => {
                        const text = document.getElementById(this.el.dataset.target)?.textContent?.trim()
                        if (!text || !navigator.clipboard) { return }
                        navigator.clipboard.writeText(text).then(() => {
                          const label = this.el.lastChild
                          const original = label.textContent
                          label.textContent = " Copied"
                          setTimeout(() => { label.textContent = original }, 1500)
                        })
                      })
                    }
                  }
                </script>
              </.section_card>
            <% not @licensed? -> %>
              <div
                id="license-required"
                class="rounded-xl border border-warn-border bg-warn-soft p-4 text-[13px] text-text2"
              >
                <span class="font-semibold text-warn">API access requires a license.</span>
                New tokens can't be created on this instance.
              </div>
            <% true -> %>
              <.section_card label="Token">
                <.form for={@form} id="token-form" phx-change="validate" phx-submit="create">
                  <.input
                    field={@form[:name]}
                    label="Name"
                    placeholder="claude-code laptop"
                    autocomplete="off"
                    spellcheck="false"
                    required
                  />
                  <.input
                    field={@form[:expires_in_days]}
                    type="select"
                    label="Expiration"
                    options={expiry_options()}
                  />
                  <p class="mb-4 text-[12px] leading-relaxed text-text3">
                    The token acts as you, with exactly your access to projects, until it expires
                    or you revoke it.
                  </p>
                  <.button variant="primary" phx-disable-with="Creating…">Create token</.button>
                </.form>
              </.section_card>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "New API token")
     |> assign(:licensed?, License.feature_enabled?(:api_access))
     |> assign(:plaintext, nil)
     |> assign(:form, to_form(Accounts.change_api_token(%{"expires_in_days" => "90"})))}
  end

  @impl true
  def handle_event("validate", %{"api_token" => params}, socket) do
    form = params |> Accounts.change_api_token() |> to_form(action: :validate)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("create", %{"api_token" => params}, socket) do
    scope = socket.assigns.current_scope
    true = Accounts.sudo_mode?(scope.user)

    case Accounts.create_api_token(scope, params) do
      {:ok, plaintext, _token} ->
        {:noreply, socket |> assign(:plaintext, plaintext) |> put_flash(:info, "Token created.")}

      {:error, :license_required} ->
        {:noreply,
         socket
         |> assign(:licensed?, false)
         |> put_flash(:error, "API access requires a license.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  defp expiry_options do
    Enum.map(ApiToken.expiry_days(), &{"#{&1} days", &1}) ++ [{"No expiration", ""}]
  end
end
