defmodule CodeLeadWeb.DashboardLiveTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Tasks

  setup :register_and_log_in_user

  defp tile_value(view, id) do
    view
    |> element("#" <> id)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".font-mono")
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "empty instance" do
    test "offers to create the first project, with the sidebar intact", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#create-first-project[href="/settings/projects/new"]})
      assert has_element?(view, "#nav-dashboard")
      assert has_element?(view, "#account-card")
      refute has_element?(view, "#tile-review")
    end
  end

  describe "attention tiles" do
    test "count states across every project", %{conn: conn} do
      project_a = project_fixture()
      project_b = project_fixture()

      put_context!(task_fixture(project_a.id), state: :review)
      put_context!(task_fixture(project_b.id), state: :review)
      put_context!(task_fixture(project_a.id), state: :running, run_state: :failed)
      put_context!(task_fixture(project_b.id), state: :running, run_state: :queued)

      {:ok, view, _html} = live(conn, ~p"/")

      assert tile_value(view, "tile-review") == "2"
      assert tile_value(view, "tile-failed") == "1"
      assert tile_value(view, "tile-waiting-input") == "0"
    end

    test "counts agent questions and permission requests as waiting for input", %{conn: conn} do
      project = project_fixture()

      {:ok, _} =
        project.id
        |> task_fixture()
        |> Tasks.set_attention(:agent_question, "which retention window?")

      {:ok, _} =
        project.id
        |> task_fixture()
        |> Tasks.set_attention(:permission_request, "allow network access?")

      {:ok, view, _html} = live(conn, ~p"/")

      assert tile_value(view, "tile-waiting-input") == "2"
    end

    test "reports a task executing without a runner process as stalled", %{conn: conn} do
      project = project_fixture()
      put_context!(task_fixture(project.id), state: :running, run_state: :executing)

      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#tile-stalled") |> render() =~ "Executing with no runner"
    end
  end

  describe "panels" do
    test "list waiting tasks, active runs and completions", %{conn: conn} do
      project = project_fixture()

      {:ok, waiting} =
        project.id
        |> task_fixture(%{title: "Needs a decision"})
        |> Tasks.set_attention(:agent_question, "which retention window?")

      running =
        put_context!(task_fixture(project.id, %{title: "In flight"}),
          state: :running,
          run_state: :executing
        )

      done =
        put_context!(task_fixture(project.id, %{title: "Shipped it"}),
          state: :done,
          completed_at: DateTime.add(DateTime.utc_now(:second), -2, :hour)
        )

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{a[href="/projects/#{project.id}/tasks/#{waiting.id}"]})
      assert has_element?(view, ~s{a[href="/projects/#{project.id}/tasks/#{running.id}"]})
      assert has_element?(view, ~s{a[href="/projects/#{project.id}/tasks/#{done.id}"]})
      assert render(view) =~ "Needs a decision"
      assert render(view) =~ "Shipped it"
    end

    test "the project row links to its board", %{conn: conn} do
      project = project_fixture()
      task_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{a[href="/projects/#{project.id}/board"]}, project.name)
    end
  end

  describe "live refresh" do
    # One org subscription picks up changes in any project, and each one
    # arms a trailing-edge timer rather than reloading per event — a burst
    # of run transitions costs a single reload. Asserting immediately after
    # the change, the way BoardLiveTest does, would fail here; both halves
    # are the contract.
    test "coalesces org-wide changes into one debounced reload", %{conn: conn} do
      project = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, _task} =
        project.id
        |> task_fixture(%{title: "Arrived late"})
        |> Tasks.set_attention(:agent_question, "which retention window?")

      refute render(view) =~ "Arrived late"

      send(view.pid, :refresh)
      assert render(view) =~ "Arrived late"
    end
  end

  describe "global search" do
    test "does not search until the query reaches 3 characters", %{conn: conn} do
      project = project_fixture()
      task_fixture(project.id, %{title: "Billing task"})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#global-search-form", %{"query" => "bi"}) |> render_change()
      refute has_element?(view, "#global-search-results")

      view |> form("#global-search-form", %{"query" => "bil"}) |> render_change()
      assert has_element?(view, "#global-search-results")
    end

    test "shows matching, non-archived tasks with their project color and status", %{
      conn: conn
    } do
      project = project_fixture(%{color: :teal})
      match = task_fixture(project.id, %{title: "Rework the billing pipeline"})

      put_context!(task_fixture(project.id, %{title: "Old billing task"}),
        archived_at: DateTime.utc_now(:second)
      )

      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#global-search-form", %{"query" => "billing"}) |> render_change()

      assert has_element?(
               view,
               "#global-search-result-#{match.id}",
               "Rework the billing pipeline"
             )

      assert has_element?(view, "#global-search-result-#{match.id} .bg-proj-teal")
      refute has_element?(view, ~s{a[href$="Old billing task"]})
      assert view |> element("#global-search-results") |> render() =~ "Planning"
    end

    test "clicking a result navigates to its task page", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Rework the billing pipeline"})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#global-search-form", %{"query" => "billing"}) |> render_change()

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#global-search-result-#{task.id}") |> render_click()

      assert to == ~p"/projects/#{project.id}/tasks/#{task.id}"
    end

    test "arrow-down then enter navigates to the second result", %{conn: conn} do
      project = project_fixture()
      older = task_fixture(project.id, %{title: "Billing task A"})
      _newer = task_fixture(project.id, %{title: "Billing task B"})
      put_context!(older, updated_at: DateTime.add(DateTime.utc_now(:second), -60, :second))

      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#global-search-form", %{"query" => "billing"}) |> render_change()

      hook = element(view, "#global-search")
      render_hook(hook, "nav", %{"key" => "ArrowDown"})

      assert {:error, {:live_redirect, %{to: to}}} = render_hook(hook, "nav", %{"key" => "Enter"})
      assert to == ~p"/projects/#{project.id}/tasks/#{older.id}"
    end

    test "hints at more results past the first five, without making them clickable", %{
      conn: conn
    } do
      project = project_fixture()
      for n <- 1..7, do: task_fixture(project.id, %{title: "Billing task #{n}"})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#global-search-form", %{"query" => "billing"}) |> render_change()

      html = view |> element("#global-search-results") |> render()
      assert html =~ "2 more results"
      assert LazyHTML.from_fragment(html) |> LazyHTML.query("a") |> length() == 5
    end
  end
end
