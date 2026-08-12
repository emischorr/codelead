defmodule CodeLead.Scheduler.GatesTest do
  use CodeLead.DataCase, async: true

  import CodeLead.TasksFixtures

  alias CodeLead.Scheduler.Gates.ScheduleGate
  alias CodeLead.Tasks.Task

  describe "ScheduleGate" do
    test "admits a task with no start time" do
      assert ScheduleGate.check(%Task{scheduled_at: nil}) == :ok
    end

    test "holds until a future start time, reporting the time" do
      at = DateTime.add(DateTime.utc_now(:second), 3600)

      assert ScheduleGate.check(%Task{scheduled_at: at}) == {:hold, {:scheduled, at}}
    end

    test "admits a start time that has already passed" do
      at = DateTime.add(DateTime.utc_now(:second), -60)

      assert ScheduleGate.check(%Task{scheduled_at: at}) == :ok
    end
  end

  describe "Task.scheduled?/1" do
    test "agrees with the gate, so the badge cannot claim what the scheduler denies" do
      %{task: task} = runnable_task_fixture()

      future = %{task | scheduled_at: DateTime.add(DateTime.utc_now(:second), 3600)}
      past = %{task | scheduled_at: DateTime.add(DateTime.utc_now(:second), -3600)}

      assert Task.scheduled?(future)
      assert match?({:hold, {:scheduled, _at}}, ScheduleGate.check(future))

      refute Task.scheduled?(past)
      assert ScheduleGate.check(past) == :ok
    end
  end
end
