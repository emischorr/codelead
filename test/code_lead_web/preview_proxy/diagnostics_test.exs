defmodule CodeLeadWeb.PreviewProxy.DiagnosticsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Projects
  alias CodeLeadWeb.PreviewProxy.Diagnostics
  alias CodeLeadWeb.PreviewProxy.ErrorPages

  @origin "http://localhost:4000"

  defp repo_task(repository_attrs) do
    project = project_fixture()
    repository = repository_fixture(project.id, repository_attrs)

    task =
      task_fixture(project.id, %{target: :repo, repository_id: repository.id})

    {project, task}
  end

  test "reports the dialed address, the declared command and the injected env" do
    {_project, task} =
      repo_task(%{preview_port: 5173, preview_command: ~s(PORT="$PREVIEW_PORT" mix phx.server)})

    diagnostics = Diagnostics.collect(task, %{host: "172.17.0.1", port: 32_775}, @origin)

    assert {"proxy dialed", "172.17.0.1:32775"} in diagnostics.facts
    assert {"preview port", "5173"} in diagnostics.facts
    assert {"preview command", ~s(PORT="$PREVIEW_PORT" mix phx.server)} in diagnostics.facts
    assert {"PREVIEW_PORT", "5173"} in diagnostics.env
  end

  # The failure this whole readout exists for: a command that binds its
  # framework's default while the proxy dials the declared port.
  test "names a command that mentions neither $PREVIEW_PORT nor the port" do
    {_project, task} = repo_task(%{preview_port: 5173, preview_command: "mix phx.server"})

    assert Diagnostics.collect(task, nil, @origin).hint =~ "5173"
  end

  test "stays quiet when the command carries the port" do
    {_project, task} =
      repo_task(%{preview_port: 5173, preview_command: ~s(PORT="$PREVIEW_PORT" mix phx.server)})

    assert Diagnostics.collect(task, nil, @origin).hint == nil

    # A different port: they are unique instance-wide.
    {_project, literal} = repo_task(%{preview_port: 5174, preview_command: "vite --port 5174"})

    assert Diagnostics.collect(literal, nil, @origin).hint == nil
  end

  # The session is spawned with the project env store spliced in; that
  # half holds forge tokens and must never reach a rendered page.
  test "never carries the project env store" do
    {project, task} = repo_task(%{preview_port: 5173, preview_command: "mix phx.server"})
    {:ok, _env} = Projects.put_env(project.id, "GITHUB_TOKEN", "ghp-do-not-render")

    diagnostics = Diagnostics.collect(task, %{host: "127.0.0.1", port: 5173}, @origin)

    assert Enum.map(diagnostics.env, &elem(&1, 0)) == [
             "PREVIEW_BASE_PATH",
             "PREVIEW_ORIGIN",
             "PREVIEW_PORT"
           ]

    page = ErrorPages.not_running(%{host: "127.0.0.1", port: 5173}, diagnostics)

    refute page =~ "GITHUB_TOKEN"
    refute page =~ "ghp-do-not-render"
  end

  describe "the page itself" do
    test "renders the collected facts and escapes them" do
      diagnostics = %{
        facts: [{"preview command", ~s(sh -c "echo <hi>")}],
        env: [{"PREVIEW_BASE_PATH", ""}],
        hint: "mind the port"
      }

      page = ErrorPages.not_running(%{host: "127.0.0.1", port: 5173}, diagnostics)

      assert page =~ "Nothing is listening at 127.0.0.1:5173"
      assert page =~ "mind the port"
      assert page =~ "&lt;hi&gt;"
      refute page =~ "<hi>"
    end

    test "renders without any diagnostics at all" do
      page = ErrorPages.not_running(nil)

      assert page =~ "Nothing is listening on the preview port"
    end
  end
end
