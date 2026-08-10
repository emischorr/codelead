defmodule CodeLeadWeb.TaskLiveTest do
  use CodeLeadWeb.ConnCase, async: true

  # Requeue actions kick the real scheduler, whose TaskRunner exits on
  # the DB sandbox outside this test's ownership — expected noise.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Tasks

  defp task_path(project, task, tab \\ nil) do
    base = ~p"/projects/#{project.id}/tasks/#{task.id}"
    if tab, do: "#{base}?tab=#{tab}", else: base
  end

  describe "tab defaulting" do
    test "planning tasks open on the Task tab", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))
      assert has_element?(view, "#description-card")
    end

    test "review tasks open on the Diff tab", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :review})

      {:ok, view, _html} = live(conn, task_path(project, task))
      refute has_element?(view, "#description-card")
      assert render(view) =~ "Nothing to show yet"
    end

    test "an explicit tab param wins", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :review})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))
      assert has_element?(view, "#description-card")
    end

    test "tab links patch between tabs", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("nav a", "Terminal") |> render_click()
      assert_patch(view, task_path(project, task, "terminal"))
      assert render(view) =~ "Interactive terminal coming soon"
    end
  end

  describe "planning edits" do
    test "saving the edit form updates description and spec", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view
      |> form("#task-edit-form",
        task: %{description: "New description", spec: "New acceptance criteria"}
      )
      |> render_submit()

      assert render(view) =~ "New description"
      assert render(view) =~ "New acceptance criteria"
    end

    test "selecting an executor persists it", %{conn: conn} do
      project = project_fixture()
      executor = agent_fixture(%{roles: [:execute], work_type: :code})
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view
      |> element("#executor-form")
      |> render_change(%{"agent_id" => to_string(executor.id)})

      assert Tasks.get_task!(task.id).agent_id == executor.id
    end

    test "selecting reviewers persists them", %{conn: conn} do
      project = project_fixture()
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view
      |> element("#reviewers-form")
      |> render_change(%{"reviewer_ids" => [to_string(reviewer.id)]})

      assert [%{id: reviewer_id}] = Tasks.reviewers(task.id)
      assert reviewer_id == reviewer.id
    end
  end

  describe "review actions" do
    test "request changes sends the task back to running with the feedback", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()
      task = task |> executing_task() |> put_context!(%{state: :review, run_state: :idle})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      view |> element("#action-request-changes") |> render_click()

      view
      |> form("#feedback-form", %{feedback: "Tighten the lock scope"})
      |> render_submit()

      task = Tasks.get_task!(task.id)
      assert task.state == :running
      assert task.run_state == :queued
      assert task.next_prompt == "Tighten the lock scope"
    end

    test "send back to planning discards the execution context", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()

      # No worktree_path: a fake path would send real git teardown against
      # a repository that has no local clone.
      task =
        task
        |> executing_task()
        |> put_context!(%{state: :review, run_state: :idle, branch_name: "codelead/task-x"})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      view |> element("#action-send-back") |> render_click()

      task = Tasks.get_task!(task.id)
      assert task.state == :planning
      assert task.branch_name == nil
      assert task.acp_session_id == nil
    end
  end

  describe "attention" do
    test "shows the banner with detail", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :running, run_state: :executing})
      {:ok, task} = Tasks.set_attention(task, :agent_question, "Which retention window?")

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert render(view) =~ "Agent asks"
      assert render(view) =~ "Which retention window?"
    end
  end

  describe "agent event stream" do
    test "live events append to the feed and chunks buffer until flushed", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :running, run_state: :executing})

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      send(view.pid, {:task_event, task.id, {:message_chunk, "Thinking about "}})
      send(view.pid, {:task_event, task.id, {:message_chunk, "the fix."}})
      assert render(view) =~ "Thinking about the fix."

      send(view.pid, {:task_event, task.id, {:tool_call, %{name: "Edit", detail: "cleanup.ex"}}})
      html = render(view)
      assert html =~ "Edit cleanup.ex"
      # flushed chunk buffer became a MSG card
      assert html =~ "Thinking about the fix."
    end
  end
end
