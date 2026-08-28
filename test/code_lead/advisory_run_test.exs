defmodule CodeLead.AdvisoryRunTest do
  # async: false — swaps the :harnesses config per scenario.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.AdvisoryRun
  alias CodeLead.Executor.Context
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Attention
  alias CodeLead.Workspace

  @script Path.expand("../support/fake_acp_agent.exs", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :harnesses)
    on_exit(fn -> Application.put_env(:code_lead, :harnesses, original) end)
    :ok
  end

  defp acp_setup(scenario) do
    Application.put_env(:code_lead, :harnesses, %{claude_code: ["elixir", @script, scenario]})

    project = project_fixture()

    agent =
      agent_fixture(%{driver: :acp, harness: :claude_code, work_type: :code, roles: [:plan]})

    task = task_fixture(project.id, %{work_type: :code, target: :folder})

    path = Workspace.task_folder(task.id)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    context = %Context{type: :folder, path: path, task_id: task.id, read_only: true}

    %{task: task, agent: agent, context: context}
  end

  test "returns the terminal result, accumulating streamed chunks" do
    %{task: task, agent: agent, context: context} = acp_setup("happy")

    assert {:ok, result} = AdvisoryRun.run(task, agent, context, "survey this")
    assert result.status == :ok
    assert result.content =~ "Working on it."
  end

  test "an escalation raises attention and the run ends on its own deadline" do
    %{task: task, agent: agent, context: context} = acp_setup("permission")

    # The `permission` scenario blocks forever waiting for a decision no
    # advisory run can deliver. Before this module existed the event was
    # dropped silently and the agent hung until the caller was killed.
    assert {:error, :timeout} =
             AdvisoryRun.run(task, agent, context, "survey this", timeout: 1_500)

    task = Tasks.get_task!(task.id)
    assert task.attention.type == :permission_request
    assert task.attention.detail =~ "Delete /etc/passwd"
    assert task.attention.ref
    assert task.attention.source == :advisory

    # Despite the ref, this doesn't block an agent: nothing routes an
    # answer back to an advisory run, so the hand icon must stay off.
    refute Attention.blocks_agent?(task.attention)
  end

  test "a failing preflight is an error, not a crash" do
    %{task: task, agent: agent, context: context} = acp_setup("happy")
    Application.put_env(:code_lead, :harnesses, %{claude_code: ["claude-agent-acp-missing"]})

    assert {:error, _reason} = AdvisoryRun.run(task, agent, context, "survey this")
  end
end
