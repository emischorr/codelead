defmodule FrontSeatWeb.ApiLicenseTest do
  @moduledoc """
  The `:api_access` gate: every `/api` request, token creation in the
  context and the UI — and what must keep working without it (listing and
  revoking tokens, and tokens coming back when the feature does).
  """

  # Not async: the grant lives in `:persistent_term`, which is VM-global.
  use FrontSeatWeb.ConnCase, async: false

  import FrontSeat.AccountsFixtures
  import FrontSeat.ProjectsFixtures
  import Phoenix.LiveViewTest

  alias FrontSeat.Accounts
  alias FrontSeat.Accounts.Scope
  alias FrontSeat.License
  alias FrontSeat.LicenseHelpers
  alias FrontSeat.Repo
  alias FrontSeat.Tasks.Task
  alias FrontSeatWeb.ApiAuth

  # Tokens are minted while licensed: the point is a credential that
  # predates the lapse.
  setup %{conn: conn} do
    on_exit(&LicenseHelpers.grant_owner!/0)

    user = user_fixture()
    project = project_fixture()
    membership_fixture(project, user, :maintainer)
    {plaintext, token} = api_token_fixture(user)

    LicenseHelpers.grant_community!()

    %{conn: conn, user: user, project: project, plaintext: plaintext, token: token}
  end

  test "the owner tier includes api_access without any key change" do
    assert :api_access in License.tier_baseline(:owner).features
    refute :api_access in License.tier_baseline(:community).features
  end

  describe "without the feature" do
    test "every endpoint refuses a valid token with license_required", ctx do
      requests = [
        {:get, ~p"/api/v1/me"},
        {:get, ~p"/api/v1/projects"},
        {:get, ~p"/api/v1/projects/#{ctx.project.id}/tasks"},
        {:post, ~p"/api/v1/projects/#{ctx.project.id}/tasks"}
      ]

      for {method, path} <- requests do
        body =
          ctx.conn
          |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
          |> dispatch(@endpoint, method, path, %{title: "Nope"})
          |> json_response(403)

        assert body["error"] == %{
                 "code" => "license_required",
                 "message" => ApiAuth.license_message()
               }
      end

      assert Repo.aggregate(Task, :count) == 0
    end

    test "a request without any token gets the license error too", %{conn: conn} do
      assert %{"error" => %{"code" => "license_required"}} =
               conn |> get(~p"/api/v1/me") |> json_response(403)
    end

    test "the context refuses to create a token", %{user: user} do
      assert Accounts.create_api_token(Scope.for_user(user), %{"name" => "x"}) ==
               {:error, :license_required}
    end

    test "existing tokens are still listed and can be revoked", %{user: user, token: token} do
      scope = Scope.for_user(user)
      assert [%{id: id}] = Accounts.list_api_tokens(scope)
      assert id == token.id
      assert :ok = Accounts.delete_api_token(scope, token.id)
    end

    test "the tokens page explains the license and does not offer creation", ctx do
      {:ok, view, _html} = ctx.conn |> log_in_user(ctx.user) |> live(~p"/users/settings/tokens")

      assert has_element?(view, "#license-required")
      assert has_element?(view, "#new-token[disabled]")
      assert has_element?(view, "#token-#{ctx.token.id}")

      view |> element("#revoke-token-#{ctx.token.id}") |> render_click()
      refute has_element?(view, "#token-#{ctx.token.id}")
    end

    test "the creation page offers no form", ctx do
      {:ok, view, _html} =
        ctx.conn |> log_in_user(ctx.user) |> live(~p"/users/settings/tokens/new")

      assert has_element?(view, "#license-required")
      refute has_element?(view, "#token-form")
    end
  end

  test "a token works again once the feature returns", ctx do
    ctx.conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> get(~p"/api/v1/me")
    |> json_response(403)

    LicenseHelpers.grant_owner!()

    body =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
      |> get(~p"/api/v1/me")
      |> json_response(200)

    assert body["data"]["id"] == ctx.user.id
  end
end
