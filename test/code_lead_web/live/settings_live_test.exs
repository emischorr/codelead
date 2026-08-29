defmodule CodeLeadWeb.SettingsLiveTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures

  @moduletag role: :admin

  setup :register_and_log_in_user

  describe "overview" do
    test "renders a tile per section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      for id <- ~w(users providers agents projects organization) do
        assert has_element?(view, "#settings-tile-#{id}")
      end
    end

    test "tiles carry live counts", %{conn: conn} do
      provider = provider_fixture()
      provider_fixture()
      agent_fixture(%{provider_id: provider.id})
      project_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert render(element(view, "#settings-tile-users")) =~ "1 user"
      assert render(element(view, "#settings-tile-providers")) =~ "2 providers"
      assert render(element(view, "#settings-tile-agents")) =~ "1 agent"
      assert render(element(view, "#settings-tile-projects")) =~ "1 project"
    end

    test "the organization tile links to the organization page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "a#settings-tile-organization")
      refute has_element?(view, "#settings-tile-organization[aria-disabled]")
    end

    test "a tile navigates to its section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert {:ok, _users_view, html} =
               view
               |> element("#settings-tile-users")
               |> render_click()
               |> follow_redirect(conn, ~p"/settings/users")

      assert html =~ "Users"
    end
  end
end
