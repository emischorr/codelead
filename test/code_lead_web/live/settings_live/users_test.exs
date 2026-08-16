defmodule CodeLeadWeb.SettingsLive.UsersTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AccountsFixtures

  alias CodeLead.Accounts

  setup :register_and_log_in_user

  describe "list" do
    test "shows every user and marks the signed-in one", %{conn: conn, user: user} do
      other = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/users")

      assert has_element?(view, "#user-row-#{user.id}")
      assert has_element?(view, "#user-row-#{other.id}")
      assert render(element(view, "#user-row-#{user.id}")) =~ "You"
    end

    test "an unconfirmed user can have their invite resent", %{conn: conn} do
      pending = unconfirmed_user_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/users")

      assert render(element(view, "#user-row-#{pending.id}")) =~ "Invite pending"

      view |> element("#resend-invite-#{pending.id}") |> render_click()

      assert render(view) =~ "Login link sent"
      assert_invite_email_to(pending)
    end
  end

  describe "create" do
    test "with just a username and password the user is confirmed and can log in", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/users/new")

      view
      |> form("#user-form",
        user: %{
          username: "newuser",
          access: "password",
          password: "hello world!123",
          password_confirmation: "hello world!123"
        }
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/users")

      user = Accounts.get_user_by_username("newuser")
      refute user.email
      assert user.confirmed_at
      assert Accounts.get_user_by_username_and_password("newuser", "hello world!123")
    end

    test "with an invite the user gets a magic link and no password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/users/new")

      view
      |> form("#user-form",
        user: %{username: "invitee", email: "invitee@example.com", access: "invite"}
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/users")

      user = Accounts.get_user_by_email("invitee@example.com")
      refute user.hashed_password
      refute user.confirmed_at
      assert_invite_email_to(user)
    end

    test "an invite without an email is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/users/new")

      html =
        view
        |> form("#user-form", user: %{username: "invitee", access: "invite"})
        |> render_submit()

      assert html =~ "is required to send an invite"
      refute Accounts.get_user_by_username("invitee")
    end

    test "surfaces validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/users/new")

      html =
        view
        |> form("#user-form",
          user: %{username: "newuser", email: "nope", access: "password", password: "short"}
        )
        |> render_submit()

      assert html =~ "must have the @ sign"
      assert has_element?(view, "#user-form")
    end
  end

  describe "edit" do
    test "changes the email", %{conn: conn} do
      other = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/users/#{other.id}/edit")

      view |> form("#user-form", user: %{email: "renamed@example.com"}) |> render_submit()

      assert_patch(view, ~p"/settings/users")
      assert Accounts.get_user!(other.id).email == "renamed@example.com"
    end
  end

  describe "delete" do
    test "removes another user", %{conn: conn} do
      other = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/users")

      view |> element("#delete-user-#{other.id}") |> render_click()

      refute has_element?(view, "#user-row-#{other.id}")
    end

    test "refuses to delete the signed-in account", %{conn: conn, user: user} do
      user_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/users")

      # the control is inert, so drive the event directly
      render_click(view, "delete", %{"id" => to_string(user.id)})

      assert render(view) =~ "can&#39;t delete the account you&#39;re signed in with"
      assert Accounts.get_user!(user.id)
    end

    test "the delete control is disabled on your own row", %{conn: conn, user: user} do
      user_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/users")

      assert has_element?(view, "#delete-user-#{user.id}[disabled]")
    end
  end

  # The login fixture already put a mail in the box, so scan for ours rather
  # than asserting on the first one.
  defp assert_invite_email_to(%{id: id, email: email}) do
    assert_receive {:email, %Swoosh.Email{to: [{_name, ^email}], text_body: body}}
    assert body =~ "/users/log-in/"
    assert body =~ "expires in 72 hours"

    assert CodeLead.Repo.get_by!(CodeLead.Accounts.UserToken, user_id: id).context == "invite"
  end
end
