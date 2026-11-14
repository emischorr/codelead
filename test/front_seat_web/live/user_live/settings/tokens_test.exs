defmodule FrontSeatWeb.UserLive.Settings.TokensTest do
  use FrontSeatWeb.ConnCase, async: true

  import FrontSeat.AccountsFixtures
  import Phoenix.LiveViewTest

  alias FrontSeat.Accounts
  alias FrontSeat.Accounts.ApiToken
  alias FrontSeat.Repo

  setup :register_and_log_in_user

  describe "token list" do
    test "is linked from the account page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")
      assert has_element?(view, ~s(#manage-tokens[href="/users/settings/tokens"]))
    end

    test "lists only the user's own tokens", %{conn: conn, user: user} do
      {_plaintext, own} = api_token_fixture(user, name: "laptop")
      {_plaintext, others} = api_token_fixture(user_fixture(), name: "someone else")

      {:ok, view, _html} = live(conn, ~p"/users/settings/tokens")

      assert has_element?(view, "#token-#{own.id}", "laptop")
      refute has_element?(view, "#token-#{others.id}")
      assert has_element?(view, ~s(#new-token[href="/users/settings/tokens/new"]))
      refute has_element?(view, "#license-required")
    end

    test "does not require sudo mode, and neither does revoking", %{conn: conn} do
      user = user_fixture()
      {_plaintext, token} = api_token_fixture(user)

      {:ok, view, _html} =
        conn
        |> log_in_user(user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -60, :minute)
        )
        |> live(~p"/users/settings/tokens")

      view |> element("#revoke-token-#{token.id}") |> render_click()
      refute has_element?(view, "#token-#{token.id}")
      refute Repo.get(ApiToken, token.id)
    end

    test "marks expired tokens", %{conn: conn, user: user} do
      {_plaintext, token} =
        api_token_fixture(user, expires_at: DateTime.add(DateTime.utc_now(:second), -60))

      {:ok, view, _html} = live(conn, ~p"/users/settings/tokens")
      assert has_element?(view, "#token-#{token.id}", "Expired")
    end
  end

  describe "token creation" do
    test "requires sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings/tokens/new")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end

    test "shows the plaintext once and stores only its hash", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings/tokens/new")

      view
      |> form("#token-form", api_token: %{name: "claude-code laptop", expires_in_days: "30"})
      |> render_submit()

      plaintext =
        view
        |> element("#token-plaintext")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim()

      assert "fs_pat_" <> _ = plaintext

      assert [token] = Accounts.list_api_tokens(FrontSeat.Accounts.Scope.for_user(user))
      assert token.name == "claude-code laptop"
      assert token.expires_at
      assert token.token_hash == :crypto.hash(:sha256, plaintext)
      refute has_element?(view, "#token-form")

      # Back on the list, the plaintext is gone for good.
      {:ok, list, _html} = live(conn, ~p"/users/settings/tokens")
      refute render(list) =~ plaintext
    end

    test "shows field errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/settings/tokens/new")
      html = view |> form("#token-form", api_token: %{name: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"
      refute has_element?(view, "#token-plaintext")
    end
  end
end
