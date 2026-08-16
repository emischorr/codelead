defmodule CodeLeadWeb.SettingsLive.Users do
  @moduledoc """
  User management. With `/users/register` closed, this is the only way to add
  a person to the instance: either with an initial password (the default —
  works with no email at all), or with a magic-link invite for instances
  that have a working mail adapter. The invite lands on the same
  `/users/log-in/:token` screen the login page uses, but carries its own
  longer-lived token context.

  `role` is shown but not editable — the field is stored and nothing in the
  app authorizes on it, so offering a select would advertise enforcement that
  does not exist.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.SettingsLive.Components

  alias CodeLead.Accounts
  alias CodeLead.Accounts.User
  alias CodeLeadWeb.FlashMessages

  @access_options [
    {"Set an initial password", "password"},
    {"Send a magic-link invite", "invite"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Users") |> load_users()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    {:noreply, assign_form(socket, %User{}, %{"access" => "password"})}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :edit}} = socket) do
    user = Accounts.get_user!(id)
    {:noreply, assign_form(socket, user, %{"access" => "invite"})}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, form: nil, user: nil, access: "password")}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign_form(socket, socket.assigns.user, params)}
  end

  def handle_event("save", %{"user" => params}, %{assigns: %{live_action: :new}} = socket) do
    access = Map.get(params, "access", "password")

    case create_user_for_access(access, user_attrs(params, access)) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, created_message(user, access))
         |> maybe_invite(user, access)
         |> push_patch(to: ~p"/settings/users")
         |> load_users()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "user"), access: access)}
    end
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.update_user(socket.assigns.user, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User updated.")
         |> push_patch(to: ~p"/settings/users")
         |> load_users()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
    end
  end

  def handle_event("resend_invite", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    deliver_invite(user)

    {:noreply, put_flash(socket, :info, "Login link sent to #{user.email}.")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if String.to_integer(id) == socket.assigns.current_scope.user.id do
      {:noreply, put_flash(socket, :error, "You can't delete the account you're signed in with.")}
    else
      case id |> Accounts.get_user!() |> Accounts.delete_user() do
        {:ok, user} ->
          {:noreply, socket |> put_flash(:info, "#{user.username} deleted.") |> load_users()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, FlashMessages.delete_error(reason))}
      end
    end
  end

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <.settings_page_header title="Users" back={~p"/settings"}>
        <:actions>
          <.button id="new-user" variant="primary" patch={~p"/settings/users/new"}>
            Add user
          </.button>
        </:actions>
      </.settings_page_header>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto w-full max-w-4xl p-4 sm:p-6">
          <.section_card label={"#{length(@users)} in this organization"}>
            <div id="user-list">
              <.list_row
                :for={user <- @users}
                id={"user-row-#{user.id}"}
                title={user.username}
                subtitle={row_subtitle(user)}
              >
                <:badges>
                  <.badge variant={if user.role == :admin, do: :accent, else: :neutral}>
                    {user.role}
                  </.badge>
                  <.badge :if={is_nil(user.confirmed_at)} variant={:warn}>Invite pending</.badge>
                  <.badge :if={user.id == @current_scope.user.id} variant={:ok}>You</.badge>
                </:badges>
                <:actions>
                  <.button
                    :if={is_nil(user.confirmed_at)}
                    id={"resend-invite-#{user.id}"}
                    type="button"
                    variant="ghost"
                    phx-click="resend_invite"
                    phx-value-id={user.id}
                  >
                    Resend invite
                  </.button>
                  <.button patch={~p"/settings/users/#{user.id}/edit"}>Edit</.button>
                  <.delete_button
                    id={"delete-user-#{user.id}"}
                    value={user.id}
                    reason={delete_reason(user, @current_scope.user, @users)}
                    confirm={"Delete #{user.username}? They lose access immediately."}
                  />
                </:actions>
              </.list_row>
            </div>
          </.section_card>
        </div>
      </div>

      <.modal
        :if={@live_action in [:new, :edit]}
        id="user-modal"
        title={if @live_action == :new, do: "Add user", else: "Edit user"}
        return_to={~p"/settings/users"}
      >
        <.form for={@form} id="user-form" phx-change="validate" phx-submit="save">
          <.input
            field={@form[:username]}
            type="text"
            label="Username"
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:email]}
            type="email"
            label="Email (optional)"
            autocomplete="off"
            spellcheck="false"
          />
          <div :if={@live_action == :new}>
            <.input
              field={@form[:access]}
              type="select"
              label="How they get in"
              options={@access_options}
            />

            <div :if={@access == "password"}>
              <.input
                field={@form[:password]}
                type="password"
                label="Initial password"
                autocomplete="new-password"
                spellcheck="false"
                required
              />
              <.input
                field={@form[:password_confirmation]}
                type="password"
                label="Confirm password"
                autocomplete="new-password"
                required
              />
              <p class="mb-4 text-[12px] text-text3">
                At least 12 characters. Share it out of band and let them change it from their
                account page.
              </p>
            </div>

            <p :if={@access == "invite"} class="mb-4 text-[12px] leading-relaxed text-text3">
              Needs the email above. They get a one-time login link that expires in 72 hours.
              Use <span class="font-semibold">Resend invite</span>
              from the list if it lapses.{dev_mailbox_hint()}
            </p>
          </div>

          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/settings/users"}>Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Saving…">
              {if @live_action == :new, do: "Add user", else: "Save"}
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  ## Loading and forms

  defp load_users(socket) do
    assign(socket, users: Accounts.list_users(), access_options: @access_options)
  end

  defp assign_form(socket, user, params) do
    access = Map.get(params, "access", "password")
    user = user || %User{}

    changeset =
      user
      |> Accounts.change_user(params, with_password: access == "password" and is_nil(user.id))
      |> Map.put(:action, :validate)

    assign(socket, user: user, access: access, form: to_form(changeset, as: "user"))
  end

  # `access` is a form-only control, so it never reaches the changeset; the
  # password keys are dropped on the invite path so no hash is written.
  defp user_attrs(params, "password"), do: Map.drop(params, ["access"])

  defp user_attrs(params, _invite),
    do: Map.drop(params, ["access", "password", "password_confirmation"])

  # A magic-link invite needs somewhere to send the link, which the schema
  # itself no longer requires — that's a rule of this specific UI action, not
  # of a user in general, so it's enforced here rather than in the changeset.
  defp create_user_for_access("invite", %{"email" => email} = attrs) when email in [nil, ""] do
    changeset =
      %User{}
      |> Accounts.change_user(attrs)
      |> Ecto.Changeset.add_error(:email, "is required to send an invite")
      |> Map.put(:action, :validate)

    {:error, changeset}
  end

  defp create_user_for_access(_access, attrs), do: Accounts.create_user(attrs)

  defp maybe_invite(socket, user, "invite") do
    deliver_invite(user)
    socket
  end

  defp maybe_invite(socket, _user, _password), do: socket

  defp deliver_invite(user) do
    Accounts.deliver_invite_instructions(user, &url(~p"/users/log-in/#{&1}"))
  end

  defp created_message(%{username: username}, "invite"),
    do: "#{username} invited — login link sent."

  defp created_message(%{username: username}, _password), do: "#{username} added."

  ## Row copy

  defp row_subtitle(%{email: nil} = user), do: access_summary(user)
  defp row_subtitle(%{email: email} = user), do: "#{access_summary(user)} · #{email}"

  defp access_summary(%{hashed_password: hash}) when is_binary(hash), do: "Password set"
  defp access_summary(_user), do: "Magic link only"

  defp delete_reason(%{id: id}, %{id: id}, _users),
    do: "You can't delete the account you're signed in with."

  defp delete_reason(_user, _current, [_only_one]),
    do: "The last user can't be deleted — the instance would be unreachable."

  defp delete_reason(_user, _current, _users), do: nil

  defp dev_mailbox_hint do
    if Application.get_env(:code_lead, CodeLead.Mailer)[:adapter] == Swoosh.Adapters.Local do
      " In development the mail lands in the local mailbox at /dev/mailbox."
    else
      ""
    end
  end
end
