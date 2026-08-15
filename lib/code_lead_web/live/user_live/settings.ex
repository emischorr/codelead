defmodule CodeLeadWeb.UserLive.Settings do
  @moduledoc """
  Account overview. Deliberately not sudo-gated — email/password display and
  the preferences below are the only things it touches, and neither is a
  security-sensitive action. Changing email or password *is*, so those live
  behind their own re-authenticated pages (`UserLive.Settings.Email`,
  `UserLive.Settings.Password`), and visiting this page day-to-day never
  forces a re-login.

  Preferences (language, timezone) are the user's own choice — unlike
  `role`, nothing here is admin-managed. Theme lives here too but stays
  client-only (`localStorage`, via `Layouts.theme_toggle/1`); it was only
  ever a sidebar fixture, not account data.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Accounts
  alias CodeLeadWeb.FormOptions

  @preferences_types %{locale: :string, timezone: :string}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="Account" back={~p"/settings"} />

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto flex w-full max-w-2xl flex-col gap-3.5 p-4 sm:p-6">
          <p class="text-[13px] text-text2">
            Manage your email, password, and personal preferences.
          </p>

          <.section_card label="Email">
            <:actions>
              <.button navigate={~p"/users/settings/email"}>Change email</.button>
            </:actions>
            <p class="text-[13px] text-text2">{@current_email}</p>
          </.section_card>

          <.section_card label="Password">
            <:actions>
              <.button navigate={~p"/users/settings/password"}>Change password</.button>
            </:actions>
            <p class="text-[13px] text-text2">
              Changing your password requires re-authenticating first.
            </p>
          </.section_card>

          <.section_card label="Preferences">
            <.form for={@preferences_form} id="preferences-form" phx-submit="save_preferences">
              <.input
                field={@preferences_form[:locale]}
                type="select"
                label="Language"
                options={FormOptions.locales()}
              />
              <.input
                field={@preferences_form[:timezone]}
                type="select"
                label="Timezone"
                options={FormOptions.timezones()}
              />
              <div class="mt-4 flex justify-end">
                <.button variant="primary" type="submit" phx-disable-with="Saving…">
                  Save
                </.button>
              </div>
            </.form>
          </.section_card>

          <.section_card label="Appearance">
            <div class="flex items-center justify-between">
              <p class="text-[13px] text-text2">Theme</p>
              <Layouts.theme_toggle />
            </div>
          </.section_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:current_email, user.email)
     |> assign(:preferences_form, to_form(preferences_changeset(user, %{}), as: "preferences"))}
  end

  @impl true
  def handle_event("save_preferences", %{"preferences" => params}, socket) do
    user = socket.assigns.current_scope.user
    changeset = preferences_changeset(user, params)

    if changeset.valid? do
      locale = Ecto.Changeset.get_field(changeset, :locale)
      timezone = Ecto.Changeset.get_field(changeset, :timezone)
      settings = Map.put(user.settings, "timezone", timezone)

      {:ok, updated_user} =
        Accounts.update_user(user, %{"locale" => locale, "settings" => settings})

      {:noreply,
       socket
       |> put_flash(:info, "Preferences saved.")
       |> assign(
         :preferences_form,
         to_form(preferences_changeset(updated_user, %{}), as: "preferences")
       )}
    else
      form = changeset |> Map.put(:action, :validate) |> to_form(as: "preferences")
      {:noreply, assign(socket, :preferences_form, form)}
    end
  end

  defp preferences_changeset(user, params) do
    data = %{locale: user.locale, timezone: Map.get(user.settings, "timezone", "")}

    {data, @preferences_types}
    |> Ecto.Changeset.cast(params, [:locale, :timezone])
    |> Ecto.Changeset.validate_inclusion(:locale, FormOptions.locale_values())
    |> Ecto.Changeset.validate_inclusion(:timezone, FormOptions.timezone_values())
  end
end
