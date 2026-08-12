defmodule CodeLead.PlanningSurveyTest do
  # async: false — spawns supervised runs and swaps the :harnesses config.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Costs.AgentRun
  alias CodeLead.Git
  alias CodeLead.Planning
  alias CodeLead.Projects
  alias CodeLead.Tasks
  alias CodeLead.Workspace

  @script Path.expand("../support/fake_acp_agent.exs", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :harnesses)
    on_exit(fn -> Application.put_env(:code_lead, :harnesses, original) end)

    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    :ok
  end

  defp survey_setup(scenario \\ "happy") do
    Application.put_env(:code_lead, :harnesses, %{claude_code: ["elixir", @script, scenario]})

    project = project_fixture()
    git_url = create_origin!()
    repository = repository_fixture(project.id, %{git_url: git_url})

    planner =
      agent_fixture(%{
        driver: :acp,
        harness: :claude_code,
        work_type: :code,
        roles: [:plan],
        model_variant: "claude-sonnet-5"
      })

    task =
      task_fixture(project.id, %{
        title: "Add pricing page",
        description: "Three tiers.",
        work_type: :code,
        target: :repo,
        repository_id: repository.id
      })

    on_exit(fn ->
      File.rm_rf!(Workspace.survey_worktree_path(task.id))
      File.rm_rf!(Workspace.base_clone_path(repository.name, repository.id))
    end)

    %{project: project, repository: repository, planner: planner, task: task}
  end

  defp await_survey(task_id) do
    receive do
      {:task_event, ^task_id, {:survey_completed, summary}} -> summary
    after
      20_000 -> flunk("survey never completed")
    end
  end

  test "a survey lands as a planning turn, cost-tracked and audited" do
    %{task: task, planner: planner, repository: repository} = survey_setup()
    Phoenix.PubSub.subscribe(CodeLead.PubSub, Tasks.task_topic(task.id))

    assert {:ok, :started} = Planning.start_survey(task, planner.id)
    assert %{status: :ok} = await_survey(task.id)

    assert [message] = Planning.list_messages(task.id)
    assert message.kind == :survey
    assert message.role == :assistant
    assert message.agent_id == planner.id
    assert message.content =~ "Working on it."

    assert [run] = Repo.all(AgentRun)
    assert run.task_id == task.id
    assert run.agent_id == planner.id
    assert run.status == :ok
    assert run.total_tokens > 0

    assert [step] = Enum.filter(Tasks.steps(task.id), &(&1.kind == :plan))
    assert step.executor_type == :agent
    assert step.executor_name == planner.name
    assert run.task_step_id == step.id

    # The survey leaves nothing behind: no worktree, no branch, and the
    # task's own execution context is untouched.
    base_clone = Projects.get_repository!(repository.id).base_clone_path
    refute File.dir?(Workspace.survey_worktree_path(task.id))
    assert {:ok, list} = Git.git(base_clone, ["worktree", "list", "--porcelain"])
    refute list =~ Workspace.survey_worktree_path(task.id)
    assert {:ok, branches} = Git.git(base_clone, ["branch", "--list"])
    assert branches |> String.split("\n", trim: true) |> length() == 1

    task = Tasks.get_task!(task.id)
    assert task.state == :planning
    assert task.acp_session_id == nil
    assert task.worktree_path == nil
    assert task.branch_name == nil
    assert task.attention == nil
  end

  test "a survey can be re-run after the spec is edited, appending a turn" do
    %{task: task, planner: planner} = survey_setup()
    Phoenix.PubSub.subscribe(CodeLead.PubSub, Tasks.task_topic(task.id))

    {:ok, :started} = Planning.start_survey(task, planner.id)
    await_survey(task.id)

    {:ok, task} = Tasks.update_task(task, %{spec: "Now with an enterprise tier."})

    {:ok, :started} = Planning.start_survey(task, planner.id)
    await_survey(task.id)

    assert [_first, _second] = Planning.list_messages(task.id)
  end

  test "survey turns are not replayed as chat history" do
    %{task: task, planner: planner} = survey_setup()
    Phoenix.PubSub.subscribe(CodeLead.PubSub, Tasks.task_topic(task.id))

    {:ok, :started} = Planning.start_survey(task, planner.id)
    await_survey(task.id)

    coach = agent_fixture(%{driver: :llm_api, work_type: :code, roles: [:plan]})
    test_pid = self()

    Req.Test.stub(CodeLead.LlmApiStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:llm_request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "Noted."}],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
      })
    end)

    {:ok, _reply} = Planning.send_message(task, coach.id, "What is still open?")

    assert_receive {:llm_request, request}
    contents = Enum.map_join(request["messages"], "\n", & &1["content"])

    # The preamble and the new question, but not the survey report — a
    # multi-KB artifact must not be resent on every later turn.
    assert contents =~ "What is still open?"
    refute contents =~ "Working on it."
  end

  test "an llm_api planner cannot survey, and a repo is required" do
    %{task: task, project: project} = survey_setup()

    coach = agent_fixture(%{driver: :llm_api, work_type: :code, roles: [:plan]})
    assert {:error, :not_repo_aware} = Planning.start_survey(task, coach.id)

    executor =
      agent_fixture(%{driver: :acp, harness: :claude_code, work_type: :code, roles: [:execute]})

    assert {:error, :planner_ineligible} = Planning.start_survey(task, executor.id)

    folder_task = task_fixture(project.id, %{work_type: :code, target: :folder})
    planner = agent_fixture(%{driver: :acp, harness: :claude_code, roles: [:plan]})
    assert {:error, :missing_repository} = Planning.start_survey(folder_task, planner.id)
  end
end
