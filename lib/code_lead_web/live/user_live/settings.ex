defmodule CodeLeadWeb.UserLive.Settings do
  @moduledoc """
  Account overview. Deliberately not sudo-gated — it only *displays* the
  current email, it never changes it. Changing email or password is a
  security-sensitive action and lives behind its own re-authenticated page
  (`UserLive.Settings.Email`, `UserLive.Settings.Password`), so visiting
  this page day-to-day never forces a re-login.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="Account" back={~p"/settings"} />

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto flex w-full max-w-2xl flex-col gap-3.5 p-4 sm:p-6">
          <p class="text-[13px] text-text2">Manage your email address and password.</p>

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
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :current_email, socket.assigns.current_scope.user.email)}
  end
end
