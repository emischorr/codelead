defmodule CodeLead.TasksLicenseTest do
  @moduledoc """
  The container-execution gate (`:container_execution_env`) as the Tasks
  context enforces it — the persistence half in the changeset and the
  authoritative half in the start guard.
  """

  # Not async: the grant lives in `:persistent_term`, which is VM-global.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.LicenseHelpers
  alias CodeLead.Projects
  alias CodeLead.Tasks

  # Fixtures are built while licensed, so what each test exercises is the
  # gate itself rather than a task that could never have existed.
  setup do
    on_exit(&LicenseHelpers.grant_owner!/0)

    project = project_fixture()

    repository = repository_fixture(project.id, %{env_kind: :devcontainer})

    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id,
        execution_env: :container
      })

    %{project: project, repository: repository, executor: executor, task: task}
  end

  describe "an unlicensed instance" do
    setup do
      LicenseHelpers.grant_community!()
      :ok
    end

    test "refuses to start a container task even with a declared environment", %{
      task: task,
      executor: executor
    } do
      # The repository *does* declare devcontainer execution, so
      # :missing_execution_env is ruled out and the refusal can only be
      # the licence.
      assert Tasks.startable(task, executor) == {:error, :unlicensed_execution_env}
      refute Tasks.startable?(task, executor)
    end

    test "refuses the Planning → Running transition", %{task: task} do
      assert {:error, :unlicensed_execution_env} = Tasks.move_to_running(task)
      assert Tasks.get_task!(task.id).state == :planning
    end

    test "refuses to store a fresh move to container", %{project: project, repository: repository} do
      local = task_fixture(project.id, %{target: :repo, repository_id: repository.id})

      assert {:error, changeset} = Tasks.update_task(local, %{execution_env: :container})
      assert "requires a commercial license" in errors_on(changeset).execution_env
      assert Tasks.get_task!(local.id).execution_env == :local
    end

    test "refuses to create a container task", %{project: project, repository: repository} do
      assert {:error, changeset} =
               Tasks.create_task(project.id, %{
                 title: "Containerised",
                 work_type: :code,
                 target: :repo,
                 repository_id: repository.id,
                 execution_env: :container
               })

      assert "requires a commercial license" in errors_on(changeset).execution_env
    end

    # The gate is on the licensed *act*, not on the stored value: a task
    # from a lapsed key must not become uneditable.
    test "still allows unrelated edits to a task already set to container", %{task: task} do
      assert {:ok, updated} = Tasks.update_task(task, %{title: "Renamed while lapsed"})
      assert updated.title == "Renamed while lapsed"
      assert updated.execution_env == :container
    end

    test "leaves local tasks alone", %{project: project, repository: repository} do
      local =
        task_fixture(project.id, %{target: :repo, repository_id: repository.id})

      executor = agent_fixture(%{roles: [:execute], work_type: :code})
      {:ok, local} = Tasks.set_executor(local, executor.id)

      assert local.execution_env == :local
      assert Tasks.startable(local, executor) == :ok
    end
  end

  describe "a licensed instance" do
    test "starts a container task", %{task: task, executor: executor} do
      assert Tasks.startable(task, executor) == :ok
      assert {:ok, running} = Tasks.move_to_running(task)
      assert running.state == :running
    end

    test "still refuses one whose repository declares no environment", %{
      task: task,
      repository: repository,
      executor: executor
    } do
      {:ok, _repository} = Projects.update_repository(repository, %{env_kind: :default})

      assert Tasks.startable(task, executor) == {:error, :missing_execution_env}
    end

    test "stores a move to container", %{project: project, repository: repository} do
      local = task_fixture(project.id, %{target: :repo, repository_id: repository.id})

      assert {:ok, updated} = Tasks.update_task(local, %{execution_env: :container})
      assert updated.execution_env == :container
    end
  end
end
