defmodule CodeLeadWeb.BoardLiveTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Tasks

  setup :register_and_log_in_user

  # What a `datetime-local` input posts: minute precision, no zone.
  defp input_value(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%dT%H:%M")

  # On the minute, so the round trip through the input is lossless.
  defp in_an_hour do
    at = DateTime.add(DateTime.utc_now(:second), 3600)
    %{at | second: 0}
  end

  describe "rendering" do
    test "shows all four columns with task cards", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Board render task"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      for column <- ~w(planning running review done) do
        assert has_element?(view, "#board-column-#{column}")
      end

      assert has_element?(view, "#task-card-#{task.id}")
      assert render(view) =~ "Board render task"
    end

    test "review and done cards show verdicts and commit notes", %{conn: conn} do
      project = project_fixture()

      review_task =
        task_fixture(project.id)
        |> put_context!(%{state: :review})

      CodeLead.Repo.insert!(%CodeLead.Reviews.Review{
        task_id: review_task.id,
        cycle: 1,
        verdict: :pass
      })

      done_task = task_fixture(project.id) |> put_context!(%{state: :done})
      Tasks.record_step(done_task.id, :commit, :system, "finalizer", "pushed task-branch")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert render(element(view, "#task-card-#{review_task.id}")) =~ "1 pass"
      assert render(element(view, "#task-card-#{done_task.id}")) =~ "pushed task-branch"
    end

    test "a done card links to the pull request the finalizer opened", %{conn: conn} do
      project = project_fixture()

      linked =
        task_fixture(project.id)
        |> put_context!(%{
          state: :done,
          pr_url: "https://github.com/acme/site/pull/7",
          pr_url_kind: :pull_request
        })

      unlinked = task_fixture(project.id) |> put_context!(%{state: :done})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(
               view,
               ~s(#task-card-#{linked.id}-forge-link[href="https://github.com/acme/site/pull/7"][target="_blank"])
             )

      refute has_element?(view, "#task-card-#{unlinked.id}-forge-link")
    end
  end

  describe "new-task modal" do
    test "creates a task and returns to the board", %{conn: conn} do
      project = project_fixture()
      agent_fixture(%{roles: [:execute], work_type: :code})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board/new")

      assert has_element?(view, "#new-task-form")

      view
      |> form("#new-task-form", task: %{title: "Created from modal", work_type: "code"})
      |> render_submit()

      assert_patch(view, ~p"/projects/#{project.id}/board")
      assert render(view) =~ "Created from modal"
    end

    test "shows validation errors for a missing title", %{conn: conn} do
      project = project_fixture()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board/new")

      html =
        view
        |> form("#new-task-form", task: %{title: "", work_type: "code"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "prefills the repository field with the project's default repo", %{conn: conn} do
      project = project_fixture()
      default = repository_fixture(project.id)
      _other = repository_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board/new")

      assert has_element?(
               view,
               ~s(#new-task-form select[name="task[repository_id]"] option[value="#{default.id}"][selected])
             )

      refute has_element?(
               view,
               ~s(#new-task-form select[name="task[repository_id]"] option[value=""])
             )
    end

    test "closing an empty form needs no confirmation", %{conn: conn} do
      project = project_fixture()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board/new")

      refute has_element?(view, "[data-confirm]")
    end

    test "closing a form with unsaved text asks for confirmation first", %{conn: conn} do
      project = project_fixture()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board/new")

      view
      |> form("#new-task-form", task: %{title: "Draft task"})
      |> render_change()

      assert has_element?(
               view,
               "a[data-confirm='Discard this task? Your changes will be lost.']"
             )
    end

    test "prefills the repository field with the project's default repo", %{conn: conn} do
      project = project_fixture()
      default = repository_fixture(project.id)
      _other = repository_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board/new")

      assert has_element?(
               view,
               ~s(#new-task-form select[name="task[repository_id]"] option[value="#{default.id}"][selected])
             )

      refute has_element?(
               view,
               ~s(#new-task-form select[name="task[repository_id]"] option[value=""])
             )
    end
  end

  describe "actions" do
    test "a task without an executor hides Start/Schedule on the card", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{agent_id: nil})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      refute has_element?(view, "#task-card-#{task.id}-start")
      refute has_element?(view, "#task-card-#{task.id}-schedule")

      # The handler still guards even if a stale render lets the event through.
      render_click(view, "start_task", %{"id" => to_string(task.id)})
      assert render(view) =~ "Select an executor agent"
    end

    test "a repo-target task without a repository hides Start/Schedule on the card", %{
      conn: conn
    } do
      project = project_fixture()
      executor = agent_fixture(%{roles: [:execute], work_type: :code})

      task =
        task_fixture(project.id, %{
          target: :repo,
          repository_id: nil,
          agent_id: executor.id
        })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      refute has_element?(view, "#task-card-#{task.id}-start")
      refute has_element?(view, "#task-card-#{task.id}-schedule")
    end

    test "a runnable task shows Start/Schedule on the card", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(view, "#task-card-#{task.id}-start")
      assert has_element?(view, "#task-card-#{task.id}-schedule")
    end

    test "scheduling a run moves the card to Running and shows the start time", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()
      at = in_an_hour()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      view |> element("#task-card-#{task.id}-schedule") |> render_click()
      assert has_element?(view, "#schedule-form")

      view
      |> form("#schedule-form", schedule: %{scheduled_at: input_value(at)})
      |> render_submit()

      refute has_element?(view, "#schedule-form")

      task = Tasks.get_task!(task.id)
      assert task.state == :running
      assert task.run_state == :queued
      assert task.scheduled_at == at
      assert render(view) =~ "starts"
    end

    test "a schedule without a time keeps the modal open", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      view |> element("#task-card-#{task.id}-schedule") |> render_click()

      view
      |> form("#schedule-form", schedule: %{scheduled_at: ""})
      |> render_submit()

      assert has_element?(view, "#schedule-form")
      assert Tasks.get_task!(task.id).state == :planning
    end

    test "archive removes a done card from the board", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :done})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")
      assert has_element?(view, "#task-card-#{task.id}")

      view
      |> element("#task-card-#{task.id} button", "Archive")
      |> render_click()

      refute has_element?(view, "#task-card-#{task.id}")
    end
  end

  describe "PubSub" do
    test "board refreshes when another session changes a task", %{conn: conn} do
      project = project_fixture()
      task_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      # A change made elsewhere broadcasts; this board picks it up.
      task = task_fixture(project.id, %{title: "Appeared via PubSub"})
      send(view.pid, {:board_changed, project.id, task.id})

      assert render(view) =~ "Appeared via PubSub"
    end
  end

  describe "project switcher" do
    test "colors each project's dot and pulses it while a task is running", %{conn: conn} do
      project = project_fixture(%{color: "teal"})
      other = project_fixture(%{color: "violet"})
      task_fixture(other.id) |> put_context!(%{state: :running})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(
               view,
               ~s(#project-switcher a[href="/projects/#{project.id}/board"] span.bg-proj-teal)
             )

      assert has_element?(
               view,
               ~s(#project-switcher a[href="/projects/#{other.id}/board"] span.bg-proj-violet.animate-pulse)
             )

      refute has_element?(
               view,
               ~s(#project-switcher a[href="/projects/#{project.id}/board"] span.animate-pulse)
             )
    end

    test "shows a live attention badge for every project, not just the open one", %{conn: conn} do
      project = project_fixture()
      other = project_fixture()
      other_task = task_fixture(other.id)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      badge_selector = ~s(#project-switcher a[href="/projects/#{other.id}/board"] span.bg-warn)
      refute has_element?(view, badge_selector)

      {:ok, _task} = Tasks.set_attention(other_task, :run_failed, "boom")
      send(view.pid, {:board_changed, other.id, other_task.id})

      assert has_element?(view, badge_selector, "1")
    end
  end
end
