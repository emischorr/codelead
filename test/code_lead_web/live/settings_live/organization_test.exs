defmodule CodeLeadWeb.SettingsLive.OrganizationTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeLead.Accounts

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
end
