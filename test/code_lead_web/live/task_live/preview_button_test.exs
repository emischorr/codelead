defmodule CodeLeadWeb.TaskLive.PreviewButtonTest do
  # async: false — preview sessions register globally by task id.
  use CodeLeadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Preview

  setup :register_and_log_in_user

  defp review_task(repository_attrs) do
    project = project_fixture()
    repository = repository_fixture(project.id, repository_attrs)

    task =
      project.id
      |> task_fixture(%{target: :repo, repository_id: repository.id})
      |> put_context!(%{state: :review})

    %{project: project, repository: repository, task: task}
  end

  defp worktree! do
    dir = Path.join(System.tmp_dir!(), "preview_worktree_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp review_path(project, task), do: ~p"/projects/#{project.id}/tasks/#{task.id}?tab=review"

  test "no Start button without a declared preview command", %{conn: conn} do
    %{project: project, task: task} = review_task(%{preview_port: 5173})

    {:ok, view, _html} = live(conn, review_path(project, task))

    refute has_element?(view, "#preview-server-start")
    assert has_element?(view, "#preview-open")
  end

  test "start shows the status chip, stop returns to the idle button", %{conn: conn} do
    %{project: project, task: task} =
      review_task(%{preview_port: 5173, preview_command: "sleep 30"})

    task = put_context!(task, %{worktree_path: worktree!()})
    on_exit(fn -> Preview.stop(task.id) end)

    {:ok, view, _html} = live(conn, review_path(project, task))

    assert has_element?(view, "#preview-server-start")
    refute has_element?(view, "#preview-server-stop")

    view |> element("#preview-server-start") |> render_click()

    assert has_element?(view, "#preview-server-stop")
    assert has_element?(view, "#preview-run-status")
    assert render(element(view, "#preview-run-status")) =~ "Starting"

    view |> element("#preview-server-stop") |> render_click()

    assert has_element?(view, "#preview-server-start")
    refute has_element?(view, "#preview-server-stop")
  end

  test "a start without a worktree flashes the reason", %{conn: conn} do
    %{project: project, task: task} =
      review_task(%{preview_port: 5173, preview_command: "sleep 30"})

    {:ok, view, _html} = live(conn, review_path(project, task))
    view |> element("#preview-server-start") |> render_click()

    assert render(view) =~ "no worktree yet"
    refute has_element?(view, "#preview-server-stop")
  end
end
