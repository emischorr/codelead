defmodule CodeLead.RuntimeTest do
  # async: false — swaps harness config, concurrency caps, and uses the
  # shared Req.Test stub with runtime-supervised processes.
  use CodeLead.DataCase, async: false
  use Oban.Testing, repo: CodeLead.Repo

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.AgentFeed
  alias CodeLead.Costs.AgentRun
  alias CodeLead.Projects
  alias CodeLead.Runtime
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Runtime.ScheduledDispatchWorker
  alias CodeLead.Tasks

  @script Path.expand("../support/fake_acp_agent.exs", __DIR__)

  setup do
    original_harnesses = Application.get_env(:code_lead, :harnesses)
    original_max = Application.get_env(:code_lead, :max_concurrent_runs)

    on_exit(fn ->
      Application.put_env(:code_lead, :harnesses, original_harnesses)
      Application.put_env(:code_lead, :max_concurrent_runs, original_max)
    end)

    :ok
  end

  defp use_scenario(scenario) do
    Application.put_env(:code_lead, :harnesses, %{claude_code: ["elixir", @script, scenario]})
  end

  defp acp_task(task_attrs \\ %{}) do
    project = project_fixture()

    agent =
      agent_fixture(%{driver: :acp, harness: :claude_code, work_type: :code, roles: [:execute]})

    task =
      task_fixture(
        project.id,
        Map.merge(
          %{work_type: :code, target: :folder, agent_id: agent.id, description: "Do it."},
          task_attrs
        )
      )

    %{project: project, agent: agent, task: task}
  end

  defp subscribe(task) do
    Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")
    Phoenix.PubSub.subscribe(CodeLead.PubSub, "project:#{task.project_id}")
  end

  defp latest_question_row(task_id) do
    task_id |> AgentFeed.list_run() |> Enum.filter(&(&1.kind == :question)) |> List.last()
  end

  defp await_runner_down(task_id) do
    case RunSupervisor.whereis(task_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
        :ok
    end
  end

  describe "the full run loop" do
    test "start_task dispatches, streams events, and lands in Review" do
      use_scenario("happy")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)

      assert_receive {:task_event, _id, {:run_started, _agent_name}}, 15_000
      assert_receive {:task_event, _id, {:message_chunk, "Working on it. "}}, 15_000
      assert_receive {:agent_feed, _id, %{kind: :tool_call, text: "Read README"}}, 15_000
      assert_receive {:task_event, _id, {:run_completed, result}}, 15_000
      assert result.usage.total_tokens == 340

      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :review
      assert task.run_state == :idle
      assert task.attention.type == :review_ready
      assert task.acp_session_id == "fake-sess-happy"

      assert [run] = Repo.all(AgentRun)
      assert run.task_id == task.id
      assert run.total_tokens == 340
      assert run.prompt_tokens == 100
      assert run.cached_read_tokens == 180
      # The harness reported the money; it wins over the local rate table.
      assert run.cost_cents == 42
      assert run.duration_ms > 0
      assert run.status == :ok

      steps = Tasks.steps(task.id)
      assert Enum.any?(steps, &(&1.kind == :run and &1.summary == "run started"))
      assert List.last(steps).summary =~ "moved to Review"

      # the transcript: chunks coalesced per message, nothing left open.
      # The scenario's tool call lands between the two chunks, and inside
      # the resume window that reopens the row rather than splitting it.
      events = AgentFeed.list_run(task.id)
      assert [:run_started, :message, :tool_call, :result] = Enum.map(events, & &1.kind)
      assert Enum.map(events, & &1.text) |> Enum.member?("Working on it. Done.")
      refute Enum.any?(events, & &1.streaming)

      assert %{"status" => "ok", "tokens" => 340, "cost_cents" => 42, "duration_ms" => duration} =
               List.last(events).data

      assert duration > 0
    end

    test "a tool call still ends the message once the resume window has passed" do
      original = Application.get_env(:code_lead, :message_resume_window_ms)
      Application.put_env(:code_lead, :message_resume_window_ms, 0)
      on_exit(fn -> Application.put_env(:code_lead, :message_resume_window_ms, original) end)

      use_scenario("happy")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      events = AgentFeed.list_run(task.id)
      assert [:run_started, :message, :tool_call, :message, :result] = Enum.map(events, & &1.kind)
      assert ["Working on it. ", "Done."] = for(e <- events, e.kind == :message, do: e.text)
    end

    test "a tool call is one row that advances in place" do
      use_scenario("tool_updates")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      assert [tool] = task.id |> AgentFeed.list_run() |> Enum.filter(&(&1.kind == :tool_call))
      assert tool.external_id == "tc-1"
      # the title survives the two title-less updates
      assert tool.text == "Write lib/foo.ex"
      assert tool.data["status"] == "completed"
      assert tool.data["locations"] == ["lib/foo.ex"]
      # kept field by field, and only the strings — the timeout is machinery
      assert tool.data["input"] == %{"path" => "lib/foo.ex"}
    end

    test "an llm_api executor writes its output as the task artifact" do
      Req.Test.set_req_test_to_shared()
      on_exit(fn -> Req.Test.set_req_test_to_private() end)

      Req.Test.stub(CodeLead.LlmApiStub, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "# Hero copy\n\nShip faster."}],
          "usage" => %{"input_tokens" => 12, "output_tokens" => 8}
        })
      end)

      project = project_fixture()
      agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

      task =
        task_fixture(project.id, %{work_type: :content, target: :folder, agent_id: agent.id})

      subscribe(task)
      assert {:ok, _} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :review
      assert File.read!(Path.join(task_folder(task), "output.md")) =~ "Hero copy"
    end
  end

  describe "request-changes rework dispatch" do
    # End to end: a fresh run lands in Review, request-changes sends it
    # back to Running with feedback, and the resumed ACP session replays
    # its prior turn (per spec, session/load streams the whole
    # conversation back before responding — see fake_acp_agent.exs). The
    # Agent tab must show the human's feedback, not the replay.
    test "shows the feedback as its own row and drops the session/load replay" do
      use_scenario("happy")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :review
      assert task.acp_session_id == "fake-sess-happy"

      use_scenario("resume")
      assert {:ok, task} = Runtime.request_changes(task, "please add tests")
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      events = AgentFeed.list_run(task.id)
      assert [:run_started, :human_message, :message, :result] = Enum.map(events, & &1.kind)

      human_row = Enum.find(events, &(&1.kind == :human_message))
      assert human_row.text == "please add tests"

      message_row = Enum.find(events, &(&1.kind == :message))
      assert message_row.text == "continuing where we left off"
      refute message_row.text =~ "replayed"

      refute Enum.any?(events, &(&1.kind == :tool_call))
    end
  end

  describe "scheduler holds" do
    test "budget hold keeps the task queued" do
      use_scenario("happy")
      %{task: task, project: project} = acp_task()

      {:ok, _} = CodeLead.Projects.update_project(project, %{budget_limit_cents: 5})

      {:ok, _} =
        CodeLead.Costs.record_run(%{
          task_id: task.id,
          status: :ok,
          started_at: DateTime.utc_now(:second),
          usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2, cost_cents: 10}
        })

      assert {:ok, task} = Runtime.start_task(task)
      assert task.state == :running
      assert task.run_state == :queued
      assert RunSupervisor.whereis(task.id) == nil
    end

    test "capacity hold keeps the task queued until the queue is kicked" do
      use_scenario("happy")
      %{task: task} = acp_task()
      subscribe(task)

      Application.put_env(:code_lead, :max_concurrent_runs, 0)
      assert {:ok, task} = Runtime.start_task(task)
      assert task.run_state == :queued
      assert RunSupervisor.whereis(task.id) == nil

      Application.put_env(:code_lead, :max_concurrent_runs, 2)
      Runtime.kick_queue()

      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)
      assert Tasks.get_task!(task.id).state == :review
    end
  end

  describe "scheduled execution" do
    test "a future start time queues the task and books its wake-up" do
      %{task: task} = runnable_task_fixture()
      at = DateTime.add(DateTime.utc_now(:second), 3600)

      assert {:ok, task} = Runtime.start_task(task, scheduled_at: at)

      # The card moves now — that is the authorisation. Only dispatch waits.
      assert task.state == :running
      assert task.run_state == :queued
      assert task.scheduled_at == at
      assert RunSupervisor.whereis(task.id) == nil

      assert_enqueued(worker: ScheduledDispatchWorker, args: %{task_id: task.id})
    end

    test "the executor guard still fires at schedule time" do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "No executor"})

      assert {:error, :no_executor} =
               Runtime.start_task(task, scheduled_at: DateTime.add(DateTime.utc_now(:second), 60))

      refute_enqueued(worker: ScheduledDispatchWorker)
    end

    test "kick_queue leaves a task whose time has not come" do
      %{task: task} = runnable_task_fixture()
      at = DateTime.add(DateTime.utc_now(:second), 3600)

      {:ok, task} = Runtime.start_task(task, scheduled_at: at)
      Runtime.kick_queue()

      assert Tasks.get_task!(task.id).run_state == :queued
      assert RunSupervisor.whereis(task.id) == nil
    end

    test "cancelling back to Planning drops the schedule" do
      %{task: task} = runnable_task_fixture()
      at = DateTime.add(DateTime.utc_now(:second), 3600)

      {:ok, task} = Runtime.start_task(task, scheduled_at: at)

      assert {:ok, task} = Runtime.cancel_task(task)
      assert task.state == :planning
      assert task.scheduled_at == nil
    end

    test "run_now clears the schedule so nothing holds the task back" do
      %{task: task} = runnable_task_fixture()
      at = DateTime.add(DateTime.utc_now(:second), 3600)

      {:ok, task} = Runtime.start_task(task, scheduled_at: at)

      # Held at capacity so the assertion is about the schedule, not
      # about a real run starting.
      Application.put_env(:code_lead, :max_concurrent_runs, 0)

      assert {:ok, task} = Runtime.run_now(task)
      assert task.scheduled_at == nil
      assert task.run_state == :queued
    end

    test "no start time books no wake-up" do
      %{task: task} = runnable_task_fixture()

      # Held at capacity so this test is about the absence of scheduling,
      # not about a run starting — dispatch is covered elsewhere.
      Application.put_env(:code_lead, :max_concurrent_runs, 0)

      assert {:ok, task} = Runtime.start_task(task)
      assert task.run_state == :queued
      assert task.scheduled_at == nil

      refute_enqueued(worker: ScheduledDispatchWorker)
    end
  end

  describe "cancel and failure" do
    test "cancel_task terminates the agent and returns the card to Planning" do
      use_scenario("permission")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _} = Runtime.start_task(task)

      # The permission scenario stalls awaiting a human decision.
      assert_receive {:task_event, _id, {:permission_request, _detail}}, 15_000

      task = Tasks.get_task!(task.id)
      assert task.attention.type == :permission_request

      assert {:ok, task} = Runtime.cancel_task(task)
      assert task.state == :planning
      assert task.run_state == :idle

      await_runner_down(task.id)
    end

    test "an escalated permission can be approved from the console" do
      use_scenario("permission")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:permission_request, %{id: request_id}}}, 15_000

      task = Tasks.get_task!(task.id)
      assert :ok = Runtime.answer_permission(task, request_id, true)

      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :review
    end

    test "an agent question holds the run and completes it once answered" do
      use_scenario("elicitation")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:question, %{id: request_id}}}, 15_000

      # The turn is blocked on the human, so the run must not have taken
      # the automatic completion edge into Review.
      task = Tasks.get_task!(task.id)
      assert task.state == :running
      assert task.run_state == :executing
      assert task.attention.type == :agent_question
      assert task.attention.detail == "Which approach should I take?"
      assert task.attention.ref == to_string(request_id)

      row = latest_question_row(task.id)
      assert row.external_id == to_string(request_id)
      assert is_nil(row.data["resolved"])

      # Reloaded from jsonb, so every key here is proof the row was
      # written string-keyed all the way down.
      assert [%{"key" => "question_0", "type" => "select", "options" => options} | _rest] =
               row.data["fields"]

      assert [%{"value" => "Refactor first", "label" => "Refactor first"} | _] = options

      assert :ok =
               Runtime.answer_question(task, request_id, {:accept, %{"question_0" => "Ship it"}})

      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :review
      assert is_nil(task.attention) or task.attention.type == :review_ready

      row = latest_question_row(task.id)
      assert row.data["resolved"] == "answered"
      assert row.data["answers"] == %{"question_0" => "Ship it"}
      assert row.data["fields"] != nil
    end

    test "skipping a question lets the run finish without an answer" do
      use_scenario("elicitation")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:question, %{id: request_id}}}, 15_000

      task = Tasks.get_task!(task.id)
      assert :ok = Runtime.answer_question(task, request_id, :decline)

      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      assert latest_question_row(task.id).data["resolved"] == "skipped"
      assert Tasks.get_task!(task.id).state == :review
    end

    test "cancel_task releases a run blocked on a question" do
      use_scenario("elicitation")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:question, _question}}, 15_000

      task = Tasks.get_task!(task.id)
      assert {:ok, task} = Runtime.cancel_task(task)
      assert task.state == :planning
      assert is_nil(task.attention)

      await_runner_down(task.id)
    end

    test "agent crash marks the run failed with attention; retry succeeds" do
      use_scenario("crash")
      %{task: task} = acp_task()
      subscribe(task)

      assert {:ok, _} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_failed, detail}}, 15_000
      assert detail =~ "exited with status 3"
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :running
      assert task.run_state == :failed
      assert task.attention.type == :run_failed

      use_scenario("happy")
      assert {:ok, _} = Runtime.retry_task(task)
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)
      assert Tasks.get_task!(task.id).state == :review
    end
  end

  describe "dispatch failures" do
    test "a missing harness names the binary and never clones the repository" do
      Application.put_env(:code_lead, :harnesses, %{claude_code: ["claude-agent-acp-missing"]})
      %{task: task, repository: repository} = repo_task()
      subscribe(task)

      assert {:ok, _} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_failed, detail}}, 15_000
      assert detail =~ "claude-agent-acp-missing"
      assert detail =~ "not found on PATH"
      await_runner_down(task.id)

      # Preflight runs ahead of provisioning: nothing was cloned.
      assert Tasks.get_task!(task.id).worktree_path == nil
      assert Projects.get_repository!(repository.id).base_clone_path == nil
    end

    test "an unreachable remote reports the git failure, not a bare tuple" do
      use_scenario("happy")

      %{task: task} = repo_task(git_url: "file:///nonexistent/codelead-missing.git")
      subscribe(task)

      assert {:ok, _} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_failed, detail}}, 15_000
      assert detail =~ "could not prepare the workspace"
      assert detail =~ "does not appear to be a git repository"
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.run_state == :failed
      assert task.attention.type == :run_failed
    end
  end

  defp repo_task(opts \\ []) do
    project = project_fixture()
    git_url = Keyword.get_lazy(opts, :git_url, &create_origin!/0)
    repository = repository_fixture(project.id, %{git_url: git_url, default_branch: "main"})

    agent =
      agent_fixture(%{driver: :acp, harness: :claude_code, work_type: :code, roles: [:execute]})

    task =
      task_fixture(project.id, %{
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: agent.id,
        description: "Do it."
      })

    %{project: project, agent: agent, task: task, repository: repository}
  end

  defp task_folder(task), do: CodeLead.Workspace.task_folder(task.id)
end
