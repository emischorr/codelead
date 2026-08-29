defmodule CodeLead.TasksFixtures do
  @moduledoc """
  Test fixtures for the Tasks context.
  """

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures

  alias CodeLead.Repo
  alias CodeLead.Tasks
  alias CodeLead.Tasks.TaskStateTransition

  def task_fixture(project_id, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        project_id,
        Enum.into(attrs, %{
          title: "Task #{System.unique_integer([:positive])}",
          work_type: :code
        })
      )

    task
  end

  @doc """
  A `:code`/`:repo` task with a linked repository and an eligible
  executor already set — ready for `move_to_running/1`.
  """
  def runnable_task_fixture(attrs \\ %{}) do
    project = project_fixture()
    repository = repository_fixture(project.id)
    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(
        project.id,
        Enum.into(attrs, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id,
          agent_id: executor.id
        })
      )

    %{task: task, project: project, repository: repository, executor: executor}
  end

  @doc """
  A fresh admin's scope — authorizes any action without membership rows.
  The context helpers below stay user-free by forcing state through
  `apply_transition/3`, which deliberately does not authorize.
  """
  def admin_scope do
    CodeLead.AccountsFixtures.user_scope_fixture(CodeLead.AccountsFixtures.admin_fixture())
  end

  @doc """
  Drives a task through move_to_running → begin_dispatch →
  mark_executing, returning the executing task.
  """
  def executing_task(task, session_id \\ "sess-1") do
    {:ok, task} =
      Tasks.apply_transition(task, {:planning, :running},
        actor: :human,
        summary: "moved to Running (queued)"
      )

    {:ok, task} = Tasks.begin_dispatch(task)
    {:ok, task} = Tasks.mark_executing(task, session_id)
    task
  end

  @doc """
  Sets execution-context fields directly, simulating a provisioned
  worktree.
  """
  def put_context!(task, attrs) do
    task |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  @doc """
  Backdates a state-transition history row directly, for tests that need
  to control "when did this task first enter Running" independently of
  `put_context!/2` (which only touches the `tasks` row itself).
  """
  def put_state_transition!(task, from_state, to_state, at) do
    Repo.insert!(%TaskStateTransition{
      task_id: task.id,
      from_state: from_state,
      to_state: to_state,
      inserted_at: DateTime.truncate(at, :second)
    })
  end
end
