defmodule CodeLeadWeb.UserLive.SettingsTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AccountsFixtures

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
end
