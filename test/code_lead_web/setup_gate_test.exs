defmodule CodeLeadWeb.SetupGateTest do
  use CodeLeadWeb.ConnCase, async: true

  import CodeLead.AccountsFixtures
  import CodeLead.ProjectsFixtures

  describe "instance not set up" do
    @describetag :setup_pending

    test "the root path redirects to the wizard", %{conn: conn} do
      assert conn |> get(~p"/") |> redirected_to() == ~p"/setup"
    end

    test "an app path redirects to the wizard before the login page", %{conn: conn} do
      assert conn |> get(~p"/projects/1/board") |> redirected_to() == ~p"/setup"
    end

    test "the login page redirects to the wizard", %{conn: conn} do
      assert conn |> get(~p"/users/log-in") |> redirected_to() == ~p"/setup"
    end

    test "the wizard renders", %{conn: conn} do
      assert conn |> get(~p"/setup") |> html_response(200) =~ "Set up CodeLead"
    end

    test "an organization without the flag still counts as pending", %{conn: conn} do
      organization_fixture(%{settings: %{}})
      assert conn |> get(~p"/") |> redirected_to() == ~p"/setup"
    end
  end

  describe "instance set up" do
    setup :register_and_log_in_user

    test "the wizard redirects to the root", %{conn: conn} do
      assert conn |> get(~p"/setup") |> redirected_to() == ~p"/"
    end

    test "app paths are reachable", %{conn: conn} do
      project = project_fixture()
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Dashboard"
      assert html =~ project.name
    end
  end

  describe "set up but not logged in" do
    test "app paths redirect to the login page", %{conn: conn} do
      assert conn |> get(~p"/") |> redirected_to() == ~p"/users/log-in"
    end

    test "the login page is reachable", %{conn: conn} do
      assert conn |> get(~p"/users/log-in") |> html_response(200) =~ "Log in"
    end
  end
end
