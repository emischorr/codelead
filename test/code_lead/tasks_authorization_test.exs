defmodule CodeLead.TasksAuthorizationTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AccountsFixtures
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Planning
  alias CodeLead.Runtime
  alias CodeLead.Tasks

  setup do
    project = project_fixture()

    scopes =
      for role <- [:reporter, :member, :maintainer], into: %{} do
        user = user_fixture()
        membership_fixture(project, user, role)
        {role, user_scope_fixture(user)}
      end

    outsider = user_scope_fixture(user_fixture())

    %{project: project, scopes: Map.put(scopes, :outsider, outsider)}
  end

  describe "create_task/3" do
    test "a reporter creates and the creator is stamped", %{project: project, scopes: scopes} do
      reporter = scopes.reporter

      assert {:ok, task} =
               Tasks.create_task(reporter, project.id, %{title: "Idea", work_type: :code})

      assert task.created_by_id == reporter.user.id
    end

    test "refuses a non-member", %{project: project, scopes: scopes} do
      assert {:error, :unauthorized} =
               Tasks.create_task(scopes.outsider, project.id, %{title: "Nope", work_type: :code})
    end
  end

  describe "edit/delete as reporter" do
    test "own planning task is editable and deletable", %{project: project, scopes: scopes} do
      reporter = scopes.reporter
      {:ok, task} = Tasks.create_task(reporter, project.id, %{title: "Mine", work_type: :code})

      assert {:ok, updated} = Tasks.update_task(reporter, task, %{title: "Mine, refined"})
      assert {:ok, _} = Tasks.delete_task(reporter, updated)
    end

    test "someone else's task is off limits", %{project: project, scopes: scopes} do
      {:ok, task} =
        Tasks.create_task(scopes.member, project.id, %{title: "Theirs", work_type: :code})

      assert {:error, :unauthorized} =
               Tasks.update_task(scopes.reporter, task, %{title: "Grabbed"})

      assert {:error, :unauthorized} = Tasks.delete_task(scopes.reporter, task)
    end

    test "assigning needs operate rights even on an own task", %{
      project: project,
      scopes: scopes
    } do
      reporter = scopes.reporter
      {:ok, task} = Tasks.create_task(reporter, project.id, %{title: "Mine", work_type: :code})

      assert {:error, :unauthorized} =
               Tasks.update_task(reporter, task, %{"assignee_id" => reporter.user.id})

      assert {:ok, _} =
               Tasks.update_task(scopes.member, task, %{"assignee_id" => reporter.user.id})
    end
  end

  describe "operate gates" do
    test "reporters are refused, members pass", %{project: project, scopes: scopes} do
      task = task_fixture(project.id)

      assert {:error, :unauthorized} = Tasks.set_finalize_mode(scopes.reporter, task, "merge")
      assert {:error, :unauthorized} = Tasks.set_reviewers(scopes.reporter, task, [])
      assert {:error, :unauthorized} = Tasks.set_executor(scopes.reporter, task, 1)
      assert {:error, :unauthorized} = Tasks.move_to_running(scopes.reporter, task)
      assert {:error, :unauthorized} = Tasks.cancel_run(scopes.reporter, task)
      assert {:error, :unauthorized} = Tasks.request_changes(scopes.reporter, task, "redo")
      assert {:error, :unauthorized} = Tasks.send_back_to_planning(scopes.reporter, task)
      assert {:error, :unauthorized} = Tasks.approve(scopes.reporter, task)

      assert :ok = Tasks.set_reviewers(scopes.member, task, [])
    end

    test "runtime answer gates are refused for reporters", %{project: project, scopes: scopes} do
      task = task_fixture(project.id)

      assert {:error, :unauthorized} =
               Runtime.answer_permission(scopes.reporter, task, "ref", true)

      assert {:error, :unauthorized} =
               Runtime.answer_question(scopes.reporter, task, "ref", :decline)
    end
  end

  describe "step attribution" do
    test "a member's transition records username and user id", %{
      project: project,
      scopes: scopes
    } do
      member = scopes.member
      repository = repository_fixture(project.id)
      executor = agent_fixture(%{roles: [:execute], work_type: :code})

      task =
        task_fixture(project.id, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id,
          agent_id: executor.id
        })

      {:ok, task} = Tasks.move_to_running(member, task)

      step =
        task.id
        |> Tasks.steps()
        |> Enum.find(&(&1.kind == :transition and &1.executor_type == :human))

      assert step.executor_name == member.user.username
      assert step.user_id == member.user.id

      # System moves keep the literal actor and no user.
      {:ok, task} = Tasks.begin_dispatch(task)
      system_step = task.id |> Tasks.steps() |> List.last()
      assert system_step.executor_type == :system
      assert system_step.executor_name == "system"
      assert system_step.user_id == nil
    end

    test "archiving now writes an attributed step", %{project: project, scopes: scopes} do
      task = task_fixture(project.id)
      task = put_context!(task, %{state: :done})

      assert {:error, :unauthorized} = Tasks.archive(scopes.reporter, task)
      {:ok, archived} = Tasks.archive(scopes.member, task)

      step = archived.id |> Tasks.steps() |> List.last()
      assert step.kind == :transition
      assert step.summary == "archived"
      assert step.executor_name == scopes.member.user.username
      assert step.user_id == scopes.member.user.id
    end
  end

  describe "planning refinement" do
    # The permitted refinement kicks off a real async run that dies on
    # the DB sandbox outside this test's ownership — expected noise.
    @tag :capture_log
    test "a reporter runs it on their own task only", %{project: project, scopes: scopes} do
      planner = agent_fixture(%{roles: [:plan], work_type: :code, driver: :llm_api})

      {:ok, own} =
        Tasks.create_task(scopes.reporter, project.id, %{title: "Mine", work_type: :code})

      {:ok, theirs} =
        Tasks.create_task(scopes.member, project.id, %{title: "Theirs", work_type: :code})

      assert {:error, :unauthorized} =
               Planning.start_refinement(scopes.reporter, theirs, planner.id)

      assert {:ok, :started} = Planning.start_refinement(scopes.reporter, own, planner.id)
    end
  end
end
