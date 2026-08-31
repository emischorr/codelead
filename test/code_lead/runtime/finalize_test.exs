defmodule CodeLead.Runtime.FinalizeTest do
  # async: false — the approve worker writes through the shared sandbox.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Finalizer
  alias CodeLead.Git
  alias CodeLead.Runtime
  alias CodeLead.Runtime.LiveRuns
  alias CodeLead.Tasks

  # A repo task in Review with a real file:// origin — the push works,
  # and forge :other means no HTTP anywhere near the worker.
  defp reviewed_repo_task do
    project = project_fixture()
    git_url = create_origin!()
    repository = repository_fixture(project.id, %{git_url: git_url, default_branch: "main"})
    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        title: "Add pricing page",
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id
      })

    {:ok, context} = LocalSubprocess.provision(task)
    File.write!(Path.join(context.path, "pricing.html"), "<h1>Pricing</h1>\n")

    task = Tasks.get_task!(task.id) |> executing_task()
    {:ok, task} = Tasks.complete_run(task)
    %{task: task, context: context}
  end

  defp subscribe(task_id),
    do: Phoenix.PubSub.subscribe(CodeLead.PubSub, Tasks.task_topic(task_id))

  # The worker may still be exiting when the terminal event arrives;
  # wait its DOWN out, then drain the registry's partition processes
  # (which handle the DOWNs — the registered name is their supervisor)
  # before asserting on the registry.
  defp await_unregistered(task_id) do
    for {pid, _meta} <- LiveRuns.list(task_id) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    CodeLead.Runtime.Registry
    |> Supervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} -> _ = :sys.get_state(pid) end)

    assert LiveRuns.list(task_id) == []
  end

  test "approve claims the task and returns before the worker finishes" do
    %{task: task} = reviewed_repo_task()
    task_id = task.id
    subscribe(task_id)

    assert {:ok, claimed} = Runtime.approve(admin_scope(), task)
    assert claimed.state == :review
    assert claimed.run_state == :finalizing

    step =
      Tasks.steps(task_id)
      |> Enum.filter(&(&1.summary == "approved — finalizing"))
      |> List.last()

    assert step.executor_type == :human
    assert step.user_id

    # Drain the worker before the sandbox closes under it.
    assert_receive {:task_event, ^task_id, {:finalize_completed, _outcome}}, 20_000
  end

  test "a frozen task refuses a second approve and every review exit" do
    %{task: task} = reviewed_repo_task()
    task = put_context!(task, %{run_state: :finalizing})

    assert {:error, :finalizing} = Runtime.approve(admin_scope(), task)
    assert {:error, :finalizing} = Runtime.request_changes(admin_scope(), task, "feedback")
    assert {:error, :finalizing} = Runtime.send_back_to_planning(admin_scope(), task)
    assert {:error, :finalizing} = Tasks.set_finalize_mode(admin_scope(), task, "merge")

    # No worker was spawned and no second step recorded.
    assert LiveRuns.list(task.id) == []
    assert Enum.filter(Tasks.steps(task.id), &(&1.summary == "approved — finalizing")) == []
  end

  test "the worker finalizes to Done, clears the marker, and unregisters" do
    %{task: task, context: context} = reviewed_repo_task()
    task_id = task.id
    subscribe(task_id)

    assert {:ok, _claimed} = Runtime.approve(admin_scope(), task)
    assert_receive {:task_event, ^task_id, {:finalize_completed, outcome}}, 20_000
    assert outcome.note =~ "pushed"

    done = Tasks.get_task!(task_id)
    assert done.state == :done
    assert done.run_state == :idle
    assert done.completed_at

    {:ok, branches} = Git.remote_branches(context.base_clone_path)
    assert context.branch_name in branches

    await_unregistered(task_id)
  end

  test "a refused push lands back in review/idle with the failure persisted" do
    %{task: task, context: context} = reviewed_repo_task()
    {:ok, _} = Git.git(context.path, ["remote", "set-url", "origin", "/nope.git"])
    task_id = task.id
    subscribe(task_id)

    assert {:ok, _claimed} = Runtime.approve(admin_scope(), task)
    assert_receive {:task_event, ^task_id, {:finalize_failed, {:push_failed, _} = reason}}, 20_000

    failed = Tasks.get_task!(task_id)
    assert failed.state == :review
    assert failed.run_state == :idle
    assert failed.attention.type == :finalize_failed
    assert failed.attention.detail == Finalizer.error_message(reason)

    await_unregistered(task_id)
  end

  test "a worker crash records the failure instead of a stuck :finalizing" do
    # A :repo task with no repository: the finalizer's first act,
    # `Projects.get_repository!(nil)`, raises inside the worker — a
    # genuine crash with no injection seam in production code.
    project = project_fixture()
    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      project.id
      |> task_fixture(%{work_type: :code, target: :repo, agent_id: executor.id})
      |> put_context!(%{state: :review, repository_id: nil})

    task_id = task.id
    subscribe(task_id)

    assert {:ok, _claimed} = Runtime.approve(admin_scope(), task)

    assert_receive {:task_event, ^task_id, {:finalize_failed, {:crashed, %ArgumentError{}}}},
                   20_000

    crashed = Tasks.get_task!(task_id)
    assert crashed.state == :review
    assert crashed.run_state == :idle
    assert crashed.attention.type == :finalize_failed
    assert crashed.attention.detail =~ "ArgumentError"

    await_unregistered(task_id)
  end

  test "finalize cancels live reviewers and waits them out before pruning" do
    %{task: task, context: context} = reviewed_repo_task()
    test_pid = self()
    task_id = task.id

    reviewer =
      start_supervised!(
        Supervisor.child_spec(
          {Elixir.Task,
           fn ->
             :ok = LiveRuns.register(task_id, {:review, 999}, %{agent_name: "Critic"})
             send(test_pid, :reviewer_registered)

             receive do
               :advisory_cancel -> send(test_pid, :reviewer_cancelled)
             end
           end},
          id: make_ref(),
          restart: :temporary
        )
      )

    assert_receive :reviewer_registered
    reviewer_ref = Process.monitor(reviewer)

    {:ok, task} = Tasks.begin_finalize(admin_scope(), task)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, done, _outcome} = Runtime.finalize(task)
        assert done.state == :done
      end)

    # cancel_advisory returned before the prune, so by now the reviewer
    # has been asked and has exited — no reader saw the worktree vanish.
    assert_received :reviewer_cancelled
    assert_received {:DOWN, ^reviewer_ref, :process, _pid, _reason}
    refute File.dir?(context.path)
    refute log =~ "[error]"
  end
end
