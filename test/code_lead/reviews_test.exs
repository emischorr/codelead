defmodule CodeLead.ReviewsTest do
  # async: false — runtime processes, shared Req.Test stub, harness config.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Costs.AgentRun
  alias CodeLead.Findings
  alias CodeLead.Findings.Finding
  alias CodeLead.Reviews
  alias CodeLead.Runtime
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Tasks

  @script Path.expand("../support/fake_acp_agent.exs", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :harnesses)
    on_exit(fn -> Application.put_env(:code_lead, :harnesses, original) end)

    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    :ok
  end

  defp stub_llm(fun) do
    Req.Test.stub(CodeLead.LlmApiStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      fun.(conn, Jason.decode!(body))
    end)
  end

  defp reply(conn, text, input \\ 20, output \\ 10) do
    Req.Test.json(conn, %{
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"input_tokens" => input, "output_tokens" => output}
    })
  end

  defp content_task_with_reviewers(reviewer_count) do
    project = project_fixture()
    executor = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

    reviewers =
      for _i <- 1..reviewer_count do
        agent_fixture(%{
          driver: :llm_api,
          work_type: :content,
          roles: [:review],
          system_prompt: "You are a thorough reviewer."
        })
      end

    task =
      task_fixture(project.id, %{
        title: "Hero copy",
        work_type: :content,
        target: :folder,
        agent_id: executor.id
      })

    :ok = Tasks.set_reviewers(task, Enum.map(reviewers, & &1.id))
    %{project: project, task: task, executor: executor, reviewers: reviewers}
  end

  defp await_review_ready(task_id) do
    assert_receive {:task_event, ^task_id, {:review_cycle_completed, cycle}}, 20_000
    cycle
  end

  test "review entry fans out reviewers, records advisory rows, then raises attention" do
    %{task: task, reviewers: [r1, r2]} = content_task_with_reviewers(2)
    Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    test_pid = self()

    stub_llm(fn conn, body ->
      if body["system"] in [nil, ""] do
        reply(conn, "Ship faster with CodeLead.")
      else
        send(test_pid, {:review_prompt, body})
        reply(conn, ~s(Looks decent overall.\n{"verdict": "concerns"}))
      end
    end)

    {:ok, _} = Runtime.start_task(task)
    task_id = task.id
    assert_receive {:task_event, ^task_id, {:run_completed, _result}}, 20_000

    cycle = await_review_ready(task.id)
    assert cycle == 1

    task = Tasks.get_task!(task.id)
    assert task.state == :review
    assert task.attention.type == :review_ready

    reviews = Reviews.list_reviews(task.id)
    assert length(reviews) == 2
    assert Enum.all?(reviews, &(&1.cycle == 1))
    assert Enum.all?(reviews, &(&1.verdict == :concerns))
    assert Enum.all?(reviews, &(&1.findings =~ "Looks decent"))
    assert Enum.map(reviews, & &1.agent_id) |> Enum.sort() == Enum.sort([r1.id, r2.id])

    # the artifact (output.md written by the executor) reached the reviewer prompt
    assert_receive {:review_prompt, body}
    [%{"content" => prompt}] = body["messages"]
    assert prompt =~ "Ship faster with CodeLead."
    assert prompt =~ "output.md"

    # reviewer runs are cost-tracked (executor + 2 reviewers)
    assert Repo.aggregate(AgentRun, :count) == 3

    review_steps = Tasks.steps(task.id) |> Enum.filter(&(&1.kind == :review))
    assert length(review_steps) == 2
  end

  test "the executor and review prompts carry the planning decisions" do
    %{task: task} = content_task_with_reviewers(1)
    Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    finding =
      Repo.insert!(%Finding{
        task_id: task.id,
        phase: :planning,
        severity: :high,
        title: "Retry policy",
        observed: :open
      })

    {:ok, _finding} = Findings.resolve(finding, nil, :addressed, "retry 3x, then hold")

    test_pid = self()

    stub_llm(fn conn, body ->
      if body["system"] in [nil, ""] do
        send(test_pid, {:executor_prompt, body})
        reply(conn, "Executor output.")
      else
        send(test_pid, {:review_prompt, body})
        reply(conn, ~s({"verdict": "pass"}))
      end
    end)

    {:ok, _} = Runtime.start_task(task)
    await_review_ready(task.id)

    assert_receive {:executor_prompt, executor_body}
    [%{"content" => executor_prompt}] = executor_body["messages"]
    assert executor_prompt =~ "## Decisions"
    assert executor_prompt =~ "- Retry policy: retry 3x, then hold"

    assert_receive {:review_prompt, review_body}
    [%{"content" => review_prompt}] = review_body["messages"]
    assert review_prompt =~ "## Decisions"
    assert review_prompt =~ "- Retry policy: retry 3x, then hold"
  end

  test "a crashing reviewer records a failed review and never blocks the cycle" do
    %{task: task} = content_task_with_reviewers(1)
    Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    stub_llm(fn conn, body ->
      if body["system"] in [nil, ""] do
        reply(conn, "Executor output.")
      else
        Plug.Conn.send_resp(conn, 500, "reviewer backend down")
      end
    end)

    {:ok, _} = Runtime.start_task(task)
    await_review_ready(task.id)

    assert [review] = Reviews.list_reviews(task.id)
    assert review.verdict == nil
    assert review.findings =~ "error"

    task = Tasks.get_task!(task.id)
    assert task.attention.type == :review_ready
  end

  test "request_changes re-runs with the feedback as prompt and increments the cycle" do
    %{task: task} = content_task_with_reviewers(1)
    Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    test_pid = self()

    stub_llm(fn conn, body ->
      if body["system"] in [nil, ""] do
        send(test_pid, {:executor_prompt, hd(body["messages"])["content"]})
        reply(conn, "Draft v#{System.unique_integer([:positive])}")
      else
        reply(conn, ~s({"verdict": "pass"}))
      end
    end)

    {:ok, _} = Runtime.start_task(task)
    assert_receive {:executor_prompt, first_prompt}
    assert first_prompt =~ "Hero copy"
    assert await_review_ready(task.id) == 1

    task = Tasks.get_task!(task.id)
    {:ok, task} = Runtime.request_changes(task, "Make it punchier and shorter.")
    assert task.state in [:running, :review]

    assert_receive {:executor_prompt, second_prompt}, 20_000
    assert second_prompt == "Make it punchier and shorter."

    assert await_review_ready(task.id) == 2
    assert Reviews.current_cycle(task.id) == 2

    task = Tasks.get_task!(task.id)
    assert task.state == :review
  end

  test "send_back_to_planning tears down the worktree and deletes the branch" do
    project = project_fixture()
    git_url = CodeLead.GitHelpers.create_origin!()
    repository = repository_fixture(project.id, %{git_url: git_url, default_branch: "main"})
    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id
      })

    {:ok, context} = CodeLead.Executor.LocalSubprocess.provision(task)
    task = Tasks.get_task!(task.id)

    # walk to review
    task = executing_task(task, "sess-x")
    {:ok, task} = Tasks.complete_run(task)

    assert File.dir?(context.path)

    {:ok, task} = Runtime.send_back_to_planning(task)
    assert task.state == :planning
    assert task.worktree_path == nil
    assert task.branch_name == nil
    assert task.acp_session_id == nil

    refute File.dir?(context.path)
    {:ok, branches} = CodeLead.Git.git(context.base_clone_path, ["branch", "--list"])
    refute branches =~ context.branch_name
  end

  test "acp reviewers get a read-only context: writes are denied" do
    Application.put_env(:code_lead, :harnesses, %{
      claude_code: ["elixir", @script, "writes_file"]
    })

    project = project_fixture()

    reviewer =
      agent_fixture(%{
        driver: :acp,
        harness: :claude_code,
        work_type: :code,
        roles: [:review]
      })

    executor = agent_fixture(%{driver: :llm_api, work_type: :code, roles: [:execute]})

    task =
      task_fixture(project.id, %{work_type: :code, target: :folder, agent_id: executor.id})

    :ok = Tasks.set_reviewers(task, [reviewer.id])
    Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    stub_llm(fn conn, _body -> reply(conn, "Executor output.") end)

    {:ok, _} = Runtime.start_task(task)
    await_review_ready(task.id)

    # The fake agent tried to write hello.txt through fs/write_text_file;
    # the read-only review context must deny it.
    refute File.exists?(Path.join(CodeLead.Workspace.task_folder(task.id), "hello.txt"))

    # cleanup: wait for lingering runner if any
    case RunSupervisor.whereis(task.id) do
      nil -> :ok
      pid -> (ref = Process.monitor(pid)) && assert_receive({:DOWN, ^ref, _, _, _}, 10_000)
    end
  end
end
