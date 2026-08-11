defmodule CodeLead.AgentFeedTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.AgentFeed
  alias CodeLead.Tasks

  setup do
    project = project_fixture()
    %{task: task_fixture(project.id)}
  end

  describe "record_event/2 and update_event/2" do
    test "insert and update broadcast on the task topic", %{task: task} do
      Tasks.subscribe_task(task.id)

      event = AgentFeed.record_event(task.id, %{kind: :message, text: "Hi", streaming: true})
      assert_receive {:agent_feed, task_id, %{kind: :message, text: "Hi", streaming: true}}
      assert task_id == task.id

      AgentFeed.update_event(event, %{text: "Hi there", streaming: false})
      assert_receive {:agent_feed, _id, %{text: "Hi there", streaming: false}}
    end

    test "update merges data and ignores nil attrs", %{task: task} do
      event =
        AgentFeed.record_event(task.id, %{
          kind: :tool_call,
          text: "Read README",
          external_id: "tc-1",
          data: %{"status" => "pending", "tool_kind" => "read"}
        })

      # a tool_call_update usually carries only a status
      updated = AgentFeed.update_event(event, %{text: nil, data: %{"status" => "completed"}})

      assert updated.text == "Read README"
      assert updated.data == %{"status" => "completed", "tool_kind" => "read"}
      assert Repo.reload(updated).data["tool_kind"] == "read"
    end

    test "data is string-keyed whether written with atoms or strings", %{task: task} do
      event = AgentFeed.record_event(task.id, %{kind: :result, data: %{status: "ok", tokens: 12}})

      assert event.data == %{"status" => "ok", "tokens" => 12}
      assert Repo.reload(event).data == event.data
    end
  end

  describe "list_run/2" do
    test "returns only the newest run, ascending", %{task: task} do
      AgentFeed.record_event(task.id, %{kind: :run_started, text: "old run"})
      AgentFeed.record_event(task.id, %{kind: :message, text: "old message"})
      AgentFeed.record_event(task.id, %{kind: :run_started, text: "new run"})
      AgentFeed.record_event(task.id, %{kind: :tool_call, text: "Read README"})
      AgentFeed.record_event(task.id, %{kind: :result, text: "done"})

      assert [
               %{kind: :run_started, text: "new run"},
               %{kind: :tool_call},
               %{kind: :result}
             ] = AgentFeed.list_run(task.id)
    end

    test "returns everything when no run started", %{task: task} do
      AgentFeed.record_event(task.id, %{kind: :result, text: "dispatch failed"})

      assert [%{kind: :result, text: "dispatch failed"}] = AgentFeed.list_run(task.id)
    end

    test "keeps the newest rows when over the limit", %{task: task} do
      AgentFeed.record_event(task.id, %{kind: :run_started, text: "run"})
      for n <- 1..5, do: AgentFeed.record_event(task.id, %{kind: :message, text: "m#{n}"})

      assert ["m4", "m5"] = task.id |> AgentFeed.list_run(2) |> Enum.map(& &1.text)
    end
  end

  describe "file_changing?/2" do
    test "ignores the tool kinds that cannot touch the tree" do
      for kind <- ~w(read search think fetch switch_mode) do
        refute AgentFeed.file_changing?(:tool_call, kind), "#{kind} must not stale the diff"
      end
    end

    test "counts every writing kind, including shell execution" do
      for kind <- ~w(edit delete move execute other) do
        assert AgentFeed.file_changing?(:tool_call, kind), "#{kind} must stale the diff"
      end
    end

    test "assumes an unlabelled or unknown tool wrote something" do
      assert AgentFeed.file_changing?(:tool_call, nil)
      assert AgentFeed.file_changing?(:tool_call, "compact_context")
    end

    test "a finished run settles the diff, chatter does not" do
      assert AgentFeed.file_changing?(:result, nil)
      refute AgentFeed.file_changing?(:message, nil)
      refute AgentFeed.file_changing?(:run_started, nil)
    end
  end

  describe "list_all/2" do
    test "spans every run", %{task: task} do
      AgentFeed.record_event(task.id, %{kind: :run_started, text: "old run"})
      AgentFeed.record_event(task.id, %{kind: :run_started, text: "new run"})

      assert ["old run", "new run"] = task.id |> AgentFeed.list_all() |> Enum.map(& &1.text)
    end
  end
end
