defmodule CodeLeadWeb.UserLive.Login do
  use CodeLeadWeb, :live_view

  alias CodeLead.Accounts
  alias CodeLead.Mailer

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="rounded-2xl border border-border bg-surface p-6 shadow-sm sm:p-7">
        <h1 class="text-[19px] font-bold tracking-tight text-text">Log in</h1>
        <p class="mt-1 text-[13px] text-text2">
          <%= if @current_scope && @current_scope.user do %>
            Re-authenticate to perform sensitive actions on your account.
          <% else %>
            Welcome back. Log in with your username and password.
          <% end %>
        </p>
        <p :if={!(@current_scope && @current_scope.user)} class="mt-1 text-[13px] text-text3">
          Accounts are created by an administrator from Settings — there is no self-signup.
        </p>

        <.form
          :let={f}
          for={@form}
          id="login-form-password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="mt-5"
        >
          <.input
            readonly={!!(@current_scope && @current_scope.user)}
            field={f[:username]}
            type="text"
            label="Username"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button variant="primary" full name={@form[:remember_me].name} value="true">
            Log in and stay logged in
          </.button>
          <div class="h-2" />
          <.button full>Log in only this time</.button>
        </.form>

        <div :if={@mail_enabled?}>
          <div class="my-5 flex items-center gap-3">
            <span class="h-px flex-1 bg-border" />
            <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">or</span>
            <span class="h-px flex-1 bg-border" />
          </div>

          <.form
            :let={f}
            for={@form}
            id="login-form-magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!(@current_scope && @current_scope.user)}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              spellcheck="false"
              required
            />
            <.button full>Email me a login link</.button>
          </.form>
          <p class="mt-2 text-[12px] text-text3">
            Only works if you have an email on file.
          </p>

          <p :if={@local_mailbox?} class="mt-4 text-[12px] text-text3">
            Local mail adapter — sent emails land in <.link
              href="/dev/mailbox"
              class="font-semibold text-accent hover:underline"
            >
              the mailbox
            </.link>.
          </p>
        </div>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    username =
      Phoenix.Flash.get(socket.assigns.flash, :username) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:username)])

    email = get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"username" => username, "email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       mail_enabled?: Mailer.enabled?(),
       local_mailbox?: Mailer.local_mailbox?()
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end
end
