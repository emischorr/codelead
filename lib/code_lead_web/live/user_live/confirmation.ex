defmodule CodeLeadWeb.UserLive.Confirmation do
  use CodeLeadWeb, :live_view

  alias CodeLead.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="rounded-2xl border border-border bg-surface p-6 shadow-sm sm:p-7">
        <h1 class="text-[19px] font-bold tracking-tight text-text">Welcome</h1>
        <p class="mt-1 font-mono text-[13px] text-text2">{@user.email}</p>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation-form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
          class="mt-5"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Confirming..."
            variant="primary"
            full
          >
            Confirm and stay logged in
          </.button>
          <div class="h-2" />
          <.button phx-disable-with="Confirming..." full>
            Confirm and log in only this time
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login-form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
          class="mt-5"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope && @current_scope.user do %>
            <.button phx-disable-with="Logging in..." variant="primary" full>
              Log in
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Logging in..."
              variant="primary"
              full
            >
              Keep me logged in on this device
            </.button>
            <div class="h-2" />
            <.button phx-disable-with="Logging in..." full>
              Log me in only this time
            </.button>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at} class="mt-6 rounded-xl bg-surface2 p-3 text-[12px] text-text2">
          Prefer passwords? You can set one in your user settings.
        </p>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
