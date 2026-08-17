defmodule CodeLeadWeb.MailDisabledTest do
  @moduledoc """
  With no mail transport configured — the default for a fresh instance — every
  email surface has to be gone, not merely broken. The counterparts asserting
  the surfaces *are* there with mail on live in `login_test.exs` and
  `settings_live/users_test.exs`.

  Note the setup order: `user_fixture/1` confirms its user through a magic
  link, so the fixtures have to run before mail is switched off.
  """

  # Toggles application env, which is VM-global.
  use CodeLeadWeb.ConnCase, async: false

  import CodeLead.AccountsFixtures
  import CodeLead.MailHelpers
  import Phoenix.LiveViewTest

  alias CodeLead.Accounts

  describe "login page" do
    setup do
      disable_mail!()
    end

    test "offers no magic link and no mailbox notice", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, "#login-form-password")
      refute has_element?(view, "#login-form-magic")
      refute html =~ "Email me a login link"
      refute html =~ "/dev/mailbox"
    end
  end

  describe "settings/users" do
    setup :register_and_log_in_user

    setup do
      disable_mail!()
    end

    test "offers no invite option when adding a user", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/users/new")

      assert has_element?(view, "#user-form")
      refute has_element?(view, "#user-form select[name='user[access]']")
      refute html =~ "magic-link invite"
      assert html =~ "Initial password"
    end

    # The select is gone, so this is what a crafted submit looks like: the
    # event carries an "access" the form never offered.
    test "refuses an invite submitted anyway", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/users/new")

      html =
        render_submit(view, "save", %{
          "user" => %{
            "username" => "invitee",
            "email" => "invitee@example.com",
            "access" => "invite"
          }
        })

      assert html =~ "SMTP_HOST"
      refute Accounts.get_user_by_username("invitee")
    end

    test "hides the resend button for a user still awaiting an invite", %{conn: conn} do
      pending = unconfirmed_user_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/users")

      assert render(element(view, "#user-row-#{pending.id}")) =~ "Invite pending"
      refute has_element?(view, "#resend-invite-#{pending.id}")
    end
  end
end
