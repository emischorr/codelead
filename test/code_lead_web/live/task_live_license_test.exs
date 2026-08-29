defmodule CodeLeadWeb.TaskLiveLicenseTest do
  @moduledoc """
  How the task page presents the container-execution gate. Cosmetic by
  design — `CodeLead.TasksLicenseTest` covers the enforcement.
  """

  # Not async: the grant lives in `:persistent_term`, which is VM-global.
  use CodeLeadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.LicenseHelpers

  @moduletag role: :admin

  setup :register_and_log_in_user

  setup %{conn: conn} do
    on_exit(&LicenseHelpers.grant_owner!/0)

    project = project_fixture()
    repository = repository_fixture(project.id)

    task =
      task_fixture(project.id, %{
        work_type: :code,
        target: :repo,
        repository_id: repository.id
      })

    %{conn: conn, path: ~p"/projects/#{project.id}/tasks/#{task.id}"}
  end

  test "the Container option is offered on a licensed instance", %{conn: conn, path: path} do
    LicenseHelpers.grant_owner!()

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#target-form select[name=execution_env] option[value=container]")

    refute has_element?(
             view,
             "#target-form select[name=execution_env] option[value=container][disabled]"
           )
  end

  test "the Container option is disabled, not dropped, on an unlicensed instance", %{
    conn: conn,
    path: path
  } do
    LicenseHelpers.grant_community!()

    {:ok, view, _html} = live(conn, path)

    # Still rendered, so a task already set to :container keeps showing
    # its real value rather than falling back to Local.
    assert has_element?(
             view,
             "#target-form select[name=execution_env] option[value=container][disabled]"
           )

    refute has_element?(
             view,
             "#target-form select[name=execution_env] option[value=local][disabled]"
           )
  end
end
