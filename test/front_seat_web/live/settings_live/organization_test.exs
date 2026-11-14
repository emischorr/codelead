defmodule FrontSeatWeb.SettingsLive.OrganizationTest do
  use FrontSeatWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FrontSeat.Accounts

  @moduletag role: :admin

  setup :register_and_log_in_user

  test "saves name, org limits, and the default project budgets", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/organization")

    view
    |> form("#organization-form",
      organization: %{
        name: "Renamed Org",
        budget_limit_cents: "10000",
        default_project_budget_limit_cents: "2500",
        default_project_budget_limit_tokens: "1000000"
      }
    )
    |> render_submit()

    organization = Accounts.get_organization!()
    assert organization.name == "Renamed Org"
    assert organization.budget_limit_cents == 10_000
    assert organization.default_project_budget_limit_cents == 2500
    assert organization.default_project_budget_limit_tokens == 1_000_000
  end

  test "a blank input clears a limit and setup_done survives", %{conn: conn} do
    {:ok, _} = Accounts.update_organization(%{budget_limit_cents: 500})
    {:ok, view, _html} = live(conn, ~p"/settings/organization")

    view
    |> form("#organization-form", organization: %{name: "Test Org", budget_limit_cents: ""})
    |> render_submit()

    organization = Accounts.get_organization!()
    assert organization.budget_limit_cents == nil
    assert organization.settings["setup_done"] == true
  end

  test "a negative limit surfaces as a form error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/organization")

    html =
      view
      |> form("#organization-form", organization: %{name: "Test Org", budget_limit_cents: "-1"})
      |> render_submit()

    assert html =~ "must be greater than or equal to"
    assert Accounts.get_organization!().budget_limit_cents == nil
  end

  describe "environment" do
    test "adds a variable without ever showing its value", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/organization/env/new")

      view
      |> form("#env-form", env: %{key: "GITHUB_TOKEN", value: "ghp-super-secret"})
      |> render_submit()

      assert_patch(view, ~p"/settings/organization")
      assert has_element?(view, "#env-row-GITHUB_TOKEN")
      refute render(view) =~ "ghp-super-secret"
      assert Accounts.org_env_var("GITHUB_TOKEN") == "ghp-super-secret"
    end

    test "edits a variable", %{conn: conn, scope: scope} do
      {:ok, _} = Accounts.put_org_env(scope, "API_KEY", "s3cret")
      {:ok, view, _html} = live(conn, ~p"/settings/organization/env/API_KEY/edit")

      view
      |> form("#env-form", env: %{key: "API_KEY", value: "changed"})
      |> render_submit()

      assert_patch(view, ~p"/settings/organization")
      assert Accounts.org_env_var("API_KEY") == "changed"
    end

    test "removes a variable", %{conn: conn, scope: scope} do
      {:ok, _} = Accounts.put_org_env(scope, "API_KEY", "s3cret")
      {:ok, view, _html} = live(conn, ~p"/settings/organization")

      view |> element("#delete-env-API_KEY") |> render_click()

      refute has_element?(view, "#env-row-API_KEY")
      assert Accounts.org_env_vars() == []
    end
  end
end
