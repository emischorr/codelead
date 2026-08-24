defmodule CodeLead.TasksTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Agents
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task

  describe "create_task/2 defaults" do
    test "code defaults to repo target and picks the first linked repository" do
      project = project_fixture()
      repository = repository_fixture(project.id)

      task = task_fixture(project.id, %{work_type: :code})

      assert task.target == :repo
      assert task.repository_id == repository.id
      assert task.state == :planning
      assert task.run_state == :idle
      assert task.execution_env == :local
    end

    test "content defaults to folder target" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})
      assert task.target == :folder
      assert task.repository_id == nil
    end

    test "reviewer set is pre-filled from project defaults" do
      project = project_fixture()
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      :ok = Agents.set_default_reviewers(project.id, :code, [reviewer.id])

      task = task_fixture(project.id, %{work_type: :code})

      assert [%{id: id}] = Tasks.reviewers(task.id)
      assert id == reviewer.id
    end

    test "a devcontainer repository derives container execution" do
      project = project_fixture()
      repository_fixture(project.id, %{env_kind: :devcontainer})

      task = task_fixture(project.id, %{work_type: :code})

      assert task.execution_env == :container
    end

    test "an explicit repository choice also derives its execution shape" do
      project = project_fixture()
      repository_fixture(project.id)
      devcontainer = repository_fixture(project.id, %{env_kind: :devcontainer})

      task =
        task_fixture(project.id, %{work_type: :code, repository_id: devcontainer.id})

      assert task.execution_env == :container
    end
  end

  describe "execution_env derivation on repository change" do
    test "switching to a devcontainer repository upgrades execution" do
      project = project_fixture()
      local_repo = repository_fixture(project.id)
      devcontainer_repo = repository_fixture(project.id, %{env_kind: :devcontainer})
      task = task_fixture(project.id, %{work_type: :code, repository_id: local_repo.id})
      assert task.execution_env == :local

      assert {:ok, task} = Tasks.update_task(task, %{repository_id: devcontainer_repo.id})

      assert task.execution_env == :container
    end

    test "switching away from a devcontainer repository downgrades execution" do
      project = project_fixture()
      devcontainer_repo = repository_fixture(project.id, %{env_kind: :devcontainer})
      local_repo = repository_fixture(project.id)
      task = task_fixture(project.id, %{work_type: :code, repository_id: devcontainer_repo.id})
      assert task.execution_env == :container

      assert {:ok, task} = Tasks.update_task(task, %{repository_id: local_repo.id})

      assert task.execution_env == :local
    end

    test "a manual execution_env choice sticks when the repository is left alone" do
      project = project_fixture()
      repository = repository_fixture(project.id, %{env_kind: :devcontainer})
      task = task_fixture(project.id, %{work_type: :code, repository_id: repository.id})
      assert task.execution_env == :container

      assert {:ok, task} = Tasks.update_task(task, %{execution_env: :local})
      assert task.execution_env == :local

      # An unrelated edit that never touches repository_id must not
      # re-derive over the manual choice.
      assert {:ok, task} = Tasks.update_task(task, %{title: "Renamed"})
      assert task.execution_env == :local
    end
  end

  describe "editing" do
    test "planning allows changing the execution shape" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :code})

      assert {:ok, task} =
               Tasks.update_task(task, %{
                 work_type: :content,
                 target: :folder,
                 execution_env: :container
               })

      assert task.work_type == :content
      assert task.execution_env == :container
    end

    test "a new work type drops an ineligible executor and re-prefills reviewers" do
      project = project_fixture()
      code_executor = agent_fixture(%{roles: [:execute], work_type: :code})
      code_reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      content_reviewer = agent_fixture(%{roles: [:review], work_type: :content})
      :ok = Agents.set_default_reviewers(project.id, :code, [code_reviewer.id])
      :ok = Agents.set_default_reviewers(project.id, :content, [content_reviewer.id])

      task = task_fixture(project.id, %{work_type: :code, agent_id: code_executor.id})
      assert [%{id: id}] = Tasks.reviewers(task.id)
      assert id == code_reviewer.id

      assert {:ok, task} = Tasks.update_task(task, %{work_type: :content})

      assert task.agent_id == nil
      assert [%{id: id}] = Tasks.reviewers(task.id)
      assert id == content_reviewer.id
    end

    test "a new work type keeps an executor that stays eligible" do
      project = project_fixture()
      executor = agent_fixture(%{roles: [:execute], work_type: :code})
      task = task_fixture(project.id, %{work_type: :code, agent_id: executor.id})

      assert {:ok, task} = Tasks.update_task(task, %{priority: :high})

      assert task.agent_id == executor.id
    end

    test "a work type without default reviewers clears the stale set" do
      project = project_fixture()
      code_reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      :ok = Agents.set_default_reviewers(project.id, :code, [code_reviewer.id])
      task = task_fixture(project.id, %{work_type: :code})

      assert {:ok, task} = Tasks.update_task(task, %{work_type: :content, target: :folder})

      assert Tasks.reviewers(task.id) == []
    end

    test "switching to a repo target picks the project's first repository" do
      project = project_fixture()
      repository = repository_fixture(project.id)
      task = task_fixture(project.id, %{work_type: :content})
      assert task.repository_id == nil

      assert {:ok, task} = Tasks.update_task(task, %{target: :repo})

      assert task.target == :repo
      assert task.repository_id == repository.id
    end

    test "after planning the execution shape is locked" do
      %{task: task} = runnable_task_fixture()
      {:ok, task} = Tasks.move_to_running(task)

      {:ok, updated} =
        Tasks.update_task(task, %{
          work_type: :content,
          execution_env: :container,
          title: "New title"
        })

      assert updated.title == "New title"
      assert updated.work_type == :code
      assert updated.execution_env == :local
    end

    test "set_executor validates eligibility" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :code})
      wrong = agent_fixture(%{roles: [:review], work_type: :code})
      right = agent_fixture(%{roles: [:execute], work_type: :code})

      assert {:error, :executor_ineligible} = Tasks.set_executor(task, wrong.id)
      assert {:ok, task} = Tasks.set_executor(task, right.id)
      assert task.agent_id == right.id
    end

    test "set_reviewers validates eligibility" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :code})
      executor_only = agent_fixture(%{roles: [:execute], work_type: :code})
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})

      assert {:error, {:ineligible, [id]}} = Tasks.set_reviewers(task, [executor_only.id])
      assert id == executor_only.id

      assert :ok = Tasks.set_reviewers(task, [reviewer.id])
      assert [%{id: reviewer_id}] = Tasks.reviewers(task.id)
      assert reviewer_id == reviewer.id
    end
  end

  describe "finalize_mode/1" do
    test "defaults per target when neither task nor project names one" do
      project = project_fixture()
      repository = repository_fixture(project.id)

      repo_task =
        task_fixture(project.id, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id
        })

      folder_task = task_fixture(project.id, %{work_type: :content, target: :folder})

      assert Tasks.finalize_mode(repo_task) == :pull_request
      assert Tasks.finalize_mode(folder_task) == :artifact
    end

    test "the project default applies, and a task override beats it" do
      project = project_fixture()
      repository = repository_fixture(project.id)
      {:ok, _project} = CodeLead.Projects.put_finalize_defaults(project, %{"repo" => "merge"})

      task =
        task_fixture(project.id, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id
        })

      assert Tasks.finalize_mode(task) == :merge

      {:ok, task} = Tasks.set_finalize_mode(task, "squash")
      assert Tasks.finalize_mode(task) == :squash
    end

    test "clearing the override follows the project again, including later changes" do
      project = project_fixture()
      repository = repository_fixture(project.id)

      task =
        task_fixture(project.id, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id
        })

      {:ok, task} = Tasks.set_finalize_mode(task, "squash")
      {:ok, task} = Tasks.set_finalize_mode(task, "")
      assert task.finalize_mode == nil

      {:ok, _project} = CodeLead.Projects.put_finalize_defaults(project, %{"repo" => "merge"})
      assert Tasks.finalize_mode(task) == :merge
    end

    test "rejects a mode the task's target cannot use" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content, target: :folder})

      assert {:error, changeset} = Tasks.set_finalize_mode(task, "merge")
      assert "is invalid" in errors_on(changeset).finalize_mode
    end
  end

  describe "planning → running guards" do
    test "requires an executor" do
      project = project_fixture()
      repository_fixture(project.id)
      task = task_fixture(project.id, %{work_type: :code})

      assert {:error, :no_executor} = Tasks.move_to_running(task)
    end

    test "requires a repository for repo targets" do
      project = project_fixture()
      executor = agent_fixture(%{roles: [:execute], work_type: :code})

      task =
        task_fixture(project.id, %{work_type: :code, target: :repo, agent_id: executor.id})

      assert task.repository_id == nil
      assert {:error, :missing_repository} = Tasks.move_to_running(task)
    end

    test "a plan-role agent does not satisfy the executor guard" do
      project = project_fixture()
      repository_fixture(project.id)
      planner = agent_fixture(%{roles: [:plan], work_type: :code})
      task = task_fixture(project.id, %{work_type: :code})

      # Surveying is not executing: the guard stays keyed on :execute.
      assert {:error, :executor_ineligible} = Tasks.set_executor(task, planner.id)
      assert {:error, :no_executor} = Tasks.move_to_running(task)
    end

    test "rejects an executor that lost eligibility" do
      %{task: task, executor: executor} = runnable_task_fixture()
      {:ok, _} = Agents.update_agent(executor, %{roles: [:review]})

      assert {:error, :executor_ineligible} = Tasks.move_to_running(task)
    end

    test "enqueues and records a transition step" do
      %{task: task} = runnable_task_fixture()

      assert {:ok, task} = Tasks.move_to_running(task)
      assert task.state == :running
      assert task.run_state == :queued

      assert [step] = Tasks.steps(task.id)
      assert step.kind == :transition
      assert step.executor_type == :human
    end

    test "a container task needs a declared repository image" do
      project = project_fixture()
      repository = repository_fixture(project.id, %{env_kind: :devcontainer})
      executor = agent_fixture(%{roles: [:execute], work_type: :code})

      task =
        task_fixture(project.id, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id,
          agent_id: executor.id
        })

      # Creation derives `:container` from the devcontainer repository; the
      # guard is exercised by having the repo's declaration change later.
      assert task.execution_env == :container

      {:ok, repository} = CodeLead.Projects.update_repository(repository, %{env_kind: :default})

      assert Tasks.startable(task, executor) == {:error, :missing_execution_env}
      assert {:error, :missing_execution_env} = Tasks.move_to_running(task)

      {:ok, _repository} =
        CodeLead.Projects.update_repository(repository, %{env_kind: :devcontainer})

      assert Tasks.startable(task, executor) == :ok
      assert {:ok, _task} = Tasks.move_to_running(task)
    end

    test "a local task is unaffected by an undeclared environment" do
      %{task: task, executor: executor} = runnable_task_fixture()

      assert task.execution_env == :local
      assert Tasks.startable(task, executor) == :ok
    end
  end

  describe "run lifecycle (spec §4)" do
    test "queued → dispatched → executing → review" do
      %{task: task} = runnable_task_fixture()
      {:ok, task} = Tasks.move_to_running(task)

      assert {:ok, task} = Tasks.begin_dispatch(task)
      assert task.run_state == :dispatched

      assert {:ok, task} = Tasks.mark_executing(task, "sess-42")
      assert task.run_state == :executing
      assert task.acp_session_id == "sess-42"

      assert {:ok, task} = Tasks.complete_run(task)
      assert task.state == :review
      assert task.run_state == :idle
    end

    test "failure keeps the column, sets attention; retry re-queues" do
      %{task: task} = runnable_task_fixture()
      task = executing_task(task)

      assert {:ok, task} = Tasks.fail_run(task, "agent crashed")
      assert task.state == :running
      assert task.run_state == :failed
      assert task.attention.type == :run_failed
      assert task.attention.detail == "agent crashed"

      assert {:ok, task} = Tasks.retry_run(task)
      assert task.run_state == :queued
      assert task.attention == nil
    end

    test "cancel returns to planning and keeps the worktree" do
      %{task: task} = runnable_task_fixture()
      task = executing_task(task)
      task = put_context!(task, worktree_path: "/tmp/wt", branch_name: "codelead/task-1")

      assert {:ok, task} = Tasks.cancel_run(task)
      assert task.state == :planning
      assert task.run_state == :idle
      assert task.worktree_path == "/tmp/wt"
      assert task.branch_name == "codelead/task-1"
    end
  end

  describe "review decisions (spec §4)" do
    setup do
      %{task: task} = runnable_task_fixture()
      task = executing_task(task)
      task = put_context!(task, worktree_path: "/tmp/wt", branch_name: "b")
      {:ok, task} = Tasks.complete_run(task)
      %{task: task}
    end

    test "request changes keeps context and stores the feedback", %{task: task} do
      assert {:ok, task} = Tasks.request_changes(task, "please add tests")
      assert task.state == :running
      assert task.run_state == :queued
      assert task.worktree_path == "/tmp/wt"
      assert task.branch_name == "b"
      assert task.acp_session_id == "sess-1"
      assert task.next_prompt == "please add tests"
    end

    test "send back to planning discards context", %{task: task} do
      assert {:ok, task} = Tasks.send_back_to_planning(task)
      assert task.state == :planning
      assert task.worktree_path == nil
      assert task.branch_name == nil
      assert task.acp_session_id == nil
    end

    test "approve moves to done; archive hides from the board", %{task: task} do
      assert {:ok, task} = Tasks.approve(task)
      assert task.state == :done
      assert task.completed_at
      completed_at = task.completed_at

      assert {:ok, task} = Tasks.archive(task)
      assert task.archived_at
      # Archiving hides the card; it does not un-do the completion.
      assert task.completed_at == completed_at

      board = Tasks.board(task.project_id)
      assert board.done == []

      assert {:ok, task} = Tasks.unarchive(task)
      assert task.archived_at == nil
      assert task.completed_at == completed_at
      assert [%{id: id}] = Tasks.board(task.project_id).done
      assert id == task.id
    end
  end

  describe "invalid transitions are rejected" do
    test "every transition validates its from-state" do
      %{task: planning_task} = runnable_task_fixture()

      # From planning: only move_to_running is legal.
      assert {:error, :invalid_state} = Tasks.begin_dispatch(planning_task)
      assert {:error, :invalid_state} = Tasks.mark_executing(planning_task, "s")
      assert {:error, :invalid_state} = Tasks.complete_run(planning_task)
      assert {:error, :invalid_state} = Tasks.fail_run(planning_task, "x")
      assert {:error, :invalid_state} = Tasks.retry_run(planning_task)
      assert {:error, :invalid_state} = Tasks.cancel_run(planning_task)
      assert {:error, :invalid_state} = Tasks.request_changes(planning_task, "f")
      assert {:error, :invalid_state} = Tasks.send_back_to_planning(planning_task)
      assert {:error, :invalid_state} = Tasks.approve(planning_task)
      assert {:error, :invalid_state} = Tasks.archive(planning_task)

      # Queued but not dispatched: cannot mark executing or complete.
      {:ok, queued} = Tasks.move_to_running(planning_task)
      assert {:error, :invalid_state} = Tasks.mark_executing(queued, "s")
      assert {:error, :invalid_state} = Tasks.complete_run(queued)
      assert {:error, :invalid_state} = Tasks.move_to_running(queued)
      assert {:error, :invalid_state} = Tasks.retry_run(queued)

      # Executing: cannot re-dispatch; failing twice is invalid.
      {:ok, dispatched} = Tasks.begin_dispatch(queued)
      {:ok, executing} = Tasks.mark_executing(dispatched, "s")
      assert {:error, :invalid_state} = Tasks.begin_dispatch(executing)
      {:ok, failed} = Tasks.fail_run(executing, "boom")
      assert {:error, :invalid_state} = Tasks.fail_run(failed, "again")
      assert {:error, :invalid_state} = Tasks.complete_run(failed)

      # Review: no run-lifecycle calls.
      {:ok, retried} = Tasks.retry_run(failed)
      {:ok, dispatched} = Tasks.begin_dispatch(retried)
      {:ok, executing} = Tasks.mark_executing(dispatched, "s")
      {:ok, review} = Tasks.complete_run(executing)
      assert {:error, :invalid_state} = Tasks.begin_dispatch(review)
      assert {:error, :invalid_state} = Tasks.complete_run(review)
      assert {:error, :invalid_state} = Tasks.cancel_run(review)

      # Done: review decisions are gone.
      {:ok, done} = Tasks.approve(review)
      assert {:error, :invalid_state} = Tasks.request_changes(done, "f")
      assert {:error, :invalid_state} = Tasks.send_back_to_planning(done)
      assert {:error, :invalid_state} = Tasks.approve(done)
    end
  end

  describe "delete" do
    test "planning tasks can be deleted, done tasks cannot" do
      %{task: task} = runnable_task_fixture()
      assert {:ok, _} = Tasks.delete_task(task)
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end

      %{task: task2} = runnable_task_fixture()
      task2 = executing_task(task2)
      {:ok, task2} = Tasks.complete_run(task2)
      {:ok, task2} = Tasks.approve(task2)
      assert {:error, :not_deletable} = Tasks.delete_task(task2)
    end

    test "deleting cascades steps and reviewers" do
      project = project_fixture()
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      task = task_fixture(project.id, %{work_type: :code, target: :folder})
      :ok = Tasks.set_reviewers(task, [reviewer.id])
      Tasks.record_step(task.id, :comment, :human, "human", "note")

      assert {:ok, _} = Tasks.delete_task(task)
      assert Tasks.steps(task.id) == []
      assert Tasks.reviewers(task.id) == []
    end
  end

  describe "board and attention queries" do
    test "board groups by state and excludes archived" do
      project = project_fixture()
      t1 = task_fixture(project.id, %{work_type: :content})
      _t2 = task_fixture(project.id, %{work_type: :content})

      board = Tasks.board(project.id)
      assert length(board.planning) == 2
      assert board.running == []

      {:ok, _} = Tasks.set_attention(t1, :agent_question, "which color?")
      assert [%Task{id: id}] = Tasks.attention_tasks(project.id)
      assert id == t1.id
    end
  end

  describe "search_tasks/2" do
    test "matches on title" do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Rework the billing pipeline"})
      _other = task_fixture(project.id, %{title: "Unrelated"})

      assert %{results: [%{id: id}], total: 1} = Tasks.search_tasks("billing", 5)
      assert id == task.id
    end

    test "matches on description" do
      project = project_fixture()

      task =
        task_fixture(project.id, %{
          title: "Task one",
          description: "touches the billing pipeline"
        })

      assert %{results: [%{id: id}], total: 1} = Tasks.search_tasks("billing", 5)
      assert id == task.id
    end

    test "excludes archived tasks" do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Archived billing task"})
      put_context!(task, archived_at: DateTime.utc_now() |> DateTime.truncate(:second))

      assert %{results: [], total: 0} = Tasks.search_tasks("billing", 5)
    end

    test "ranks a title hit above a description-only hit, regardless of recency" do
      project = project_fixture()

      description_hit =
        task_fixture(project.id, %{title: "Task one", description: "mentions billing"})

      title_hit = task_fixture(project.id, %{title: "Billing task two"})

      # description_hit was created first, so is more recently updated only
      # if we don't fix updated_at — assert the ordering holds anyway.
      assert %{results: [first, second]} = Tasks.search_tasks("billing", 5)
      assert first.id == title_hit.id
      assert second.id == description_hit.id
    end

    test "orders ties by most recently updated first" do
      project = project_fixture()
      older = task_fixture(project.id, %{title: "Billing task A"})
      newer = task_fixture(project.id, %{title: "Billing task B"})

      put_context!(older, updated_at: DateTime.add(DateTime.utc_now(:second), -60, :second))

      assert %{results: [first, second]} = Tasks.search_tasks("billing", 5)
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "respects the limit and reports the total match count" do
      project = project_fixture()

      for n <- 1..7 do
        task_fixture(project.id, %{title: "Billing task #{n}"})
      end

      assert %{results: results, total: 7} = Tasks.search_tasks("billing", 5)
      assert length(results) == 5
    end
  end
end
