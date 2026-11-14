defmodule FrontSeatWeb.ApiAuthTest do
  use FrontSeatWeb.ConnCase, async: true

  import FrontSeat.AccountsFixtures

  alias FrontSeat.Accounts
  alias FrontSeat.Accounts.Scope
  alias FrontSeat.Repo

  setup do
    user = user_fixture()
    {plaintext, token} = api_token_fixture(user, name: "claude-code laptop")
    %{user: user, plaintext: plaintext, token: token}
  end

  describe "authentication" do
    test "a valid bearer token authenticates as its user", %{conn: conn, user: user} = ctx do
      body = conn |> bearer(ctx.plaintext) |> get(~p"/api/v1/me") |> json_response(200)
      assert body["data"] == %{"id" => user.id, "username" => user.username, "role" => "member"}
    end

    test "the scheme is case-insensitive", %{conn: conn} = ctx do
      conn = conn |> put_req_header("authorization", "bearer " <> ctx.plaintext)
      assert conn |> get(~p"/api/v1/me") |> json_response(200)
    end

    test "a missing token is a 401 in the error shape", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/me")
      assert_unauthorized(conn)
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="FrontSeat")]
    end

    test "malformed headers and tokens are a 401", %{conn: conn} = ctx do
      for header <- [
            "Token " <> ctx.plaintext,
            "Bearer",
            "Bearer ",
            "Bearer not-a-token",
            "Bearer " <> ctx.plaintext <> "x"
          ] do
        conn
        |> put_req_header("authorization", header)
        |> get(~p"/api/v1/me")
        |> assert_unauthorized()
      end
    end

    test "a revoked token is a 401", %{conn: conn, user: user} = ctx do
      :ok = Accounts.delete_api_token(Scope.for_user(user), ctx.token.id)
      conn |> bearer(ctx.plaintext) |> get(~p"/api/v1/me") |> assert_unauthorized()
    end

    test "an expired token is a 401", %{conn: conn, user: user} do
      {expired, _token} =
        api_token_fixture(user, expires_at: DateTime.add(DateTime.utc_now(:second), -1))

      conn |> bearer(expired) |> get(~p"/api/v1/me") |> assert_unauthorized()
    end

    test "a request stamps last_used_at", %{conn: conn} = ctx do
      conn |> bearer(ctx.plaintext) |> get(~p"/api/v1/me") |> json_response(200)
      assert Repo.reload!(ctx.token).last_used_at
    end
  end

  describe "credential separation" do
    test "a browser session does not authenticate /api", %{conn: conn, user: user} do
      conn |> log_in_user(user) |> get(~p"/api/v1/me") |> assert_unauthorized()
    end

    test "a bearer token does not authenticate a browser route", %{conn: conn} = ctx do
      conn = conn |> bearer(ctx.plaintext) |> get(~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "setup gate" do
    @describetag :setup_pending

    test "the API refuses requests before setup", %{conn: conn} = ctx do
      body = conn |> bearer(ctx.plaintext) |> get(~p"/api/v1/me") |> json_response(503)
      assert body["error"]["code"] == "setup_required"
    end
  end

  test "an unknown API route answers in the error shape", %{conn: conn} = ctx do
    conn = conn |> bearer(ctx.plaintext) |> put_req_header("accept", "application/json")

    conn = get(conn, "/api/v1/nope")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  defp bearer(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer " <> plaintext)

  defp assert_unauthorized(conn) do
    assert %{"error" => %{"code" => "unauthorized", "message" => message}} =
             json_response(conn, 401)

    assert is_binary(message)
  end
end
