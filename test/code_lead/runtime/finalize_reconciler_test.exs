defmodule CodeLead.Runtime.FinalizeReconcilerTest do
  use CodeLead.DataCase, async: true

  import CodeLead.TasksFixtures

  alias CodeLead.Runtime.FinalizeReconciler
  alias CodeLead.Tasks

  # The boot gate is off in the test env (config/test.exs), so the
  # reconciler is exercised by calling run/0 directly — the same way
  # the workspace reconciler is tested.

  defp finalizing_task do
    %{task: task} = runnable_task_fixture()
    task = executing_task(task)
    {:ok, task} = Tasks.complete_run(task)
    {:ok, task} = Tasks.begin_finalize(admin_scope(), task)
    task
  end

  test "resets an interrupted finalization for human review" do
    task = finalizing_task()

    log = ExUnit.CaptureLog.capture_log(fn -> assert FinalizeReconciler.run() == :ok end)
    assert log =~ "1 interrupted finalization"

    reset = Tasks.get_task!(task.id)
    assert reset.state == :review
    assert reset.run_state == :idle
    assert reset.attention.type == :finalize_interrupted
    assert reset.attention.detail =~ "Check the remote"
  end

  test "leaves a review/idle task untouched and stays quiet" do
    %{task: task} = runnable_task_fixture()
    task = executing_task(task)
    {:ok, task} = Tasks.complete_run(task)

    log = ExUnit.CaptureLog.capture_log(fn -> assert FinalizeReconciler.run() == :ok end)
    refute log =~ "interrupted finalization"

    untouched = Tasks.get_task!(task.id)
    assert untouched.run_state == :idle
    refute untouched.attention
  end
end
