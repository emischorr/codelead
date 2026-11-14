defmodule FrontSeatWeb.UserLive.Settings.Tokens do
  @moduledoc """
  The caller's own personal access tokens: list and revoke. Deliberately
  not sudo-gated — neither lists nor revokes create a credential, and
  removing one must never be harder than keeping it. Minting a token *is*
  sensitive, so it lives on its own re-authenticated page
  (`UserLive.Settings.NewToken`), the same split as email and password.

  API access is licensed (`:api_access`). Unlicensed, the page stays
  reachable: existing tokens are still listed and revocable, and the
  create button renders disabled with the reason — the context refuses
  creation regardless.
  """

  use FrontSeatWeb, :live_view

  import FrontSeatWeb.SettingsLive.Components

  alias FrontSeat.Accounts
  alias FrontSeat.License

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="API tokens" back={~p"/users/settings"}>
        <:actions>
          <.button
            :if={@licensed?}
            id="new-token"
            variant="primary"
            navigate={~p"/users/settings/tokens/new"}
          >
            <.icon name="hero-plus" class="size-4" /> New token
          </.button>
          <.button
            :if={!@licensed?}
            id="new-token"
            type="button"
            disabled
            title="API access requires a license"
          >
            <.icon name="hero-plus" class="size-4" /> New token
          </.button>
        </:actions>
      </.settings_page_header>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto flex w-full max-w-2xl flex-col gap-3.5 p-4 sm:p-6">
          <p class="text-[13px] leading-relaxed text-text2">
            Personal access tokens let tools such as a CLI file tasks through the FrontSeat API.
            A token acts as you, with exactly your access to projects. See <code class="font-mono text-[12px]">docs/api.md</code>.
          </p>

          <div
            :if={!@licensed?}
            id="license-required"
            class="flex items-start gap-3 rounded-xl border border-warn-border bg-warn-soft p-4"
          >
            <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0 text-warn" />
            <div class="flex flex-col gap-1 text-[13px] leading-relaxed">
              <span class="font-semibold text-warn">API access requires a license</span>
              <span class="text-text2">
                This instance's license does not include API access, so new tokens can't be
                created and existing ones are refused by the API. They stay listed and work
                again as soon as the feature is licensed. You can always revoke them.
              </span>
            </div>
          </div>

          <.section_card label="Your tokens">
            <div id="tokens">
              <p :if={@tokens == []} id="tokens-empty" class="text-[13px] text-text3">
                You have no API tokens.
              </p>
              <.list_row
                :for={token <- @tokens}
                id={"token-#{token.id}"}
                title={token.name}
                subtitle={"Created #{Format.absolute(token.inserted_at)}"}
              >
                <:badges>
                  <.badge :if={expired?(token, @now)} variant={:warn}>Expired</.badge>
                </:badges>
                <:meta>
                  <span>Last used {last_used(token.last_used_at)}</span>
                  <span>{expiry(token.expires_at, @now)}</span>
                </:meta>
                <:actions>
                  <.button
                    id={"revoke-token-#{token.id}"}
                    variant="danger"
                    type="button"
                    phx-click="revoke"
                    phx-value-id={token.id}
                    data-confirm="Revoke this token? Clients using it stop working immediately."
                  >
                    Revoke
                  </.button>
                </:actions>
              </.list_row>
            </div>
          </.section_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "API tokens")
     |> assign(:licensed?, License.feature_enabled?(:api_access))
     |> load_tokens()}
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    socket =
      with {token_id, ""} <- Integer.parse(id),
           :ok <- Accounts.delete_api_token(socket.assigns.current_scope, token_id) do
        put_flash(socket, :info, "Token revoked.")
      else
        _ -> put_flash(socket, :error, "That token no longer exists.")
      end

    {:noreply, load_tokens(socket)}
  end

  defp load_tokens(socket) do
    socket
    |> assign(:tokens, Accounts.list_api_tokens(socket.assigns.current_scope))
    |> assign(:now, DateTime.utc_now())
  end

  defp expired?(%{expires_at: nil}, _now), do: false
  defp expired?(%{expires_at: at}, now), do: not DateTime.after?(at, now)

  defp last_used(nil), do: "never"
  defp last_used(at), do: Format.relative(at)

  defp expiry(nil, _now), do: "No expiry"

  defp expiry(at, now) do
    verb = if DateTime.after?(at, now), do: "Expires", else: "Expired"
    "#{verb} #{Calendar.strftime(at, "%b %-d, %Y")}"
  end
end
