defmodule CodeLeadWeb.UserLive.SettingsTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AccountsFixtures

  alias CodeLead.Accounts

  describe "Settings page" do
    test "renders settings page without requiring re-authentication", %{conn: conn} do
      user = user_fixture()

      {:ok, _lv, html} =
        conn
        |> log_in_user(user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")

      assert html =~ user.email
      assert html =~ "Change email"
      assert html =~ "Change password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "preferences" do
    test "renders the language, timezone and theme controls", %{conn: conn} do
      user = user_fixture()

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      assert has_element?(view, "#preferences-form select#preferences_locale")
      assert has_element?(view, "#preferences-form select#preferences_timezone")
      assert has_element?(view, "button[data-phx-theme]")
    end

    test "saves the language and timezone", %{conn: conn} do
      user = user_fixture()

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      view
      |> form("#preferences-form", preferences: %{locale: "en", timezone: "Europe/Berlin"})
      |> render_submit()

      updated = Accounts.get_user!(user.id)
      assert updated.locale == "en"
      assert updated.settings["timezone"] == "Europe/Berlin"
    end

    test "rejects a timezone outside the offered list", %{conn: conn} do
      user = user_fixture()

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      html =
        view
        |> form("#preferences-form", preferences: %{locale: "en", timezone: "Mars/Olympus_Mons"})
        |> render_submit()

      assert html =~ "is invalid"
      assert Accounts.get_user!(user.id).settings["timezone"] in [nil, ""]
    end
  end
end
