defmodule CodeLeadWeb.NavigationTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Costs
  alias CodeLead.Costs.DailyMetric
  alias CodeLead.Repo

  setup :register_and_log_in_user

  describe "sidebar on a project page" do
    setup do
      %{project: project_fixture()}
    end

    test "the project switcher is the interactive disclosure", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(view, "details#project-switcher")
      refute has_element?(view, "#project-switcher[aria-disabled]")
    end

    test "dashboard, board and settings all link out", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(view, ~s{#nav-dashboard[href="/"]})
      assert has_element?(view, ~s{#nav-board[href="/projects/#{project.id}/board"]})
      assert has_element?(view, ~s{#nav-settings[href="/settings"]})
    end

    test "the mobile drawer carries its own copy of the dashboard link",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(view, ~s{#m-nav-dashboard[href="/"]})
    end

    test "the budget tile is shown", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(view, "#budget-card")
    end

    # The tile's headline names the current month, so its figure has to be
    # month-to-date — an earlier month's rollup must not inflate it.
    test "the budget tile counts this month only", %{conn: conn, project: project} do
      task = task_fixture(project.id)

      {:ok, _run} =
        Costs.record_run(%{
          task_id: task.id,
          status: :ok,
          started_at: DateTime.utc_now(:second),
          usage: %{total_tokens: 100, cost_cents: 40}
        })

      Repo.insert!(%DailyMetric{
        project_id: project.id,
        date: Date.add(Date.beginning_of_month(Date.utc_today()), -1),
        total_tokens: 5_000,
        cost_cents: 999,
        run_count: 3
      })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      card = view |> element("#budget-card") |> render()

      assert card =~ "$0.40"
      refute card =~ "$10.39"
    end

    test "the theme switch sits in the account row, not the page header",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(view, "#account-card button[data-phx-theme]")
      refute has_element?(view, "header button[data-phx-theme]")
    end
  end

  describe "sidebar on a general page" do
    test "board stays reachable and the switcher is deactivated", %{conn: conn} do
      project = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/settings")

      # No project is known until the client reports the remembered one.
      assert has_element?(view, "#project-switcher[aria-disabled]")
      refute has_element?(view, "details#project-switcher")

      render_hook(view, "nav:restore_project", %{"id" => to_string(project.id)})

      assert has_element?(view, ~s{#nav-board[href="/projects/#{project.id}/board"]})
      assert has_element?(view, "#project-switcher[aria-disabled]")
    end

    test "the budget tile stays hidden even with a project remembered", %{conn: conn} do
      project = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_hook(view, "nav:restore_project", %{"id" => to_string(project.id)})

      refute has_element?(view, "#budget-card")
    end

    test "an unknown or missing stored project falls back to the first one", %{conn: conn} do
      project = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_hook(view, "nav:restore_project", %{"id" => nil})

      assert has_element?(view, ~s{#nav-board[href="/projects/#{project.id}/board"]})
    end

    test "board is disabled when the instance has no projects", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_hook(view, "nav:restore_project", %{"id" => nil})

      assert has_element?(view, "#nav-board[aria-disabled]")
      refute has_element?(view, "a#nav-board")
    end

    test "the account page carries the same sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#project-switcher")
      assert has_element?(view, "#nav-dashboard")
      assert has_element?(view, "#nav-board")
      assert has_element?(view, ~s{#nav-settings[href="/settings"]})
    end

    test "dashboard needs no project, so it links out even with none", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, ~s{#nav-dashboard[href="/"]})
      refute has_element?(view, "#nav-dashboard[aria-disabled]")
    end
  end

  describe "rail" do
    test "carries the same items as the full sidebar", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/tasks/#{task.id}")

      assert has_element?(view, ~s{#rail-project[href="/projects/#{project.id}/board"]})
      assert has_element?(view, ~s{#rail-dashboard[href="/"]})
      assert has_element?(view, ~s{#rail-board[href="/projects/#{project.id}/board"]})
      assert has_element?(view, ~s{#rail-settings[href="/settings"]})
    end
  end
end
