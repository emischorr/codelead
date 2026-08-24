defmodule CodeLead.PlanningTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Costs.AgentRun
  alias CodeLead.Git
  alias CodeLead.Planning
  alias CodeLead.Projects
  alias CodeLead.Workspace

  defp planning_setup do
    project = project_fixture()

    agent =
      agent_fixture(%{
        driver: :llm_api,
        work_type: :code,
        roles: [:execute],
        model_variant: "claude-sonnet-5"
      })

    task =
      task_fixture(project.id, %{
        title: "Add pricing page",
        description: "Three tiers.",
        work_type: :code,
        target: :folder
      })

    %{project: project, agent: agent, task: task}
  end

  defp stub_reply(reply, capture_pid) do
    Req.Test.stub(CodeLead.LlmApiStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(capture_pid, {:llm_request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => reply}],
        "usage" => %{"input_tokens" => 30, "output_tokens" => 20}
      })
    end)
  end

  test "send_message persists both turns and records usage" do
    %{agent: agent, task: task} = planning_setup()
    stub_reply("What payment providers do you support?", self())

    assert {:ok, reply} = Planning.send_message(task, agent.id, "Help me refine this task")
    assert reply.role == :assistant
    assert reply.content == "What payment providers do you support?"

    assert [%{role: :user}, %{role: :assistant}] = Planning.list_messages(task.id)

    assert_receive {:llm_request, request}
    [preamble | _rest] = request["messages"]
    assert preamble["content"] =~ "Add pricing page"
    assert preamble["content"] =~ "Three tiers."

    assert [run] = Repo.all(AgentRun)
    assert run.task_id == task.id
    assert run.total_tokens == 50
    assert run.status == :ok
  end

  test "the chat preamble carries the planning decisions" do
    %{agent: agent, task: task} = planning_setup()

    finding =
      Repo.insert!(%CodeLead.Findings.Finding{
        task_id: task.id,
        phase: :planning,
        severity: :high,
        title: "Retry policy",
        observed: :open
      })

    {:ok, _finding} = CodeLead.Findings.resolve(finding, nil, :addressed, "retry 3x, then hold")

    stub_reply("Noted.", self())
    {:ok, _reply} = Planning.send_message(task, agent.id, "Anything open?")

    assert_receive {:llm_request, request}
    [preamble | _rest] = request["messages"]
    assert preamble["content"] =~ "## Decisions"
    assert preamble["content"] =~ "- Retry policy: retry 3x, then hold"
  end

  test "conversation history is replayed on later turns" do
    %{agent: agent, task: task} = planning_setup()
    stub_reply("Answer one", self())
    {:ok, _} = Planning.send_message(task, agent.id, "Question one")

    stub_reply("Answer two", self())
    {:ok, _} = Planning.send_message(task, agent.id, "Question two")

    assert_receive {:llm_request, _first}
    assert_receive {:llm_request, second}

    roles_and_contents =
      second["messages"] |> Enum.map(&{&1["role"], &1["content"]}) |> Enum.drop(1)

    assert [
             {"user", "Question one"},
             {"assistant", "Answer one"},
             {"user", "Question two"}
           ] = roles_and_contents
  end

  test "repo file tree is included when a base clone exists" do
    %{task: task, agent: agent, project: project} = planning_setup()
    git_url = create_origin!()
    repository = repository_fixture(project.id, %{git_url: git_url})

    base_path = Workspace.base_clone_path(repository.name, repository.id)
    {:ok, _} = Git.ensure_clone(git_url, base_path)
    {:ok, repository} = Projects.update_repository(repository, %{base_clone_path: base_path})

    {:ok, task} = CodeLead.Tasks.update_task(task, %{target: :repo, repository_id: repository.id})

    stub_reply("Looks good", self())
    {:ok, _} = Planning.send_message(task, agent.id, "What files exist?")

    assert_receive {:llm_request, request}
    [preamble | _] = request["messages"]
    assert preamble["content"] =~ "README.md"
    assert preamble["content"] =~ "read-only"
  end

  test "provider errors bubble up and are recorded as failed runs" do
    %{agent: agent, task: task} = planning_setup()

    Req.Test.stub(CodeLead.LlmApiStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:http_error, 500, _}} =
             Planning.send_message(task, agent.id, "Hello?")

    assert [run] = Repo.all(AgentRun)
    assert run.status == :error
    assert run.total_tokens == 0
  end
end
