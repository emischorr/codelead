defmodule CodeLead.RuntimeTest do
  # async: false — swaps harness config, concurrency caps, and uses the
  # shared Req.Test stub with runtime-supervised processes.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Costs.AgentRun
  alias CodeLead.Runtime
  alias CodeLead.Runtime.RunSupervisor
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
      assert_receive {:task_event, _id, {:tool_call, %{id: "tc-1"}}}, 15_000
      assert_receive {:task_event, _id, {:run_completed, result}}, 15_000
      assert result.usage.total_tokens == 140

      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :review
      assert task.run_state == :idle
      assert task.attention.type == :review_ready
      assert task.acp_session_id == "fake-sess-happy"

      assert [run] = Repo.all(AgentRun)
      assert run.task_id == task.id
      assert run.total_tokens == 140
      assert run.status == :ok

      steps = Tasks.steps(task.id)
      assert Enum.any?(steps, &(&1.kind == :run and &1.summary == "run started"))
      assert List.last(steps).summary =~ "moved to Review"
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

  defp task_folder(task), do: CodeLead.Workspace.task_folder(task.id)
end
