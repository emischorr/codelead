defmodule CodeLead.AgentDriver.AcpTest do
  # async: false — tests swap the :harnesses config per scenario.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.AgentDriver.Acp
  alias CodeLead.Executor.LocalSubprocess

  @script Path.expand("../../support/fake_acp_agent.exs", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :harnesses)
    on_exit(fn -> Application.put_env(:code_lead, :harnesses, original) end)

    project = project_fixture()

    agent =
      agent_fixture(%{
        driver: :acp,
        harness: :claude_code,
        work_type: :code,
        roles: [:execute]
      })

    task = task_fixture(project.id, %{work_type: :code, target: :folder})
    {:ok, context} = LocalSubprocess.provision(task)

    %{task: task, agent: agent, context: context}
  end

  defp use_scenario(scenario) do
    Application.put_env(:code_lead, :harnesses, %{
      claude_code: ["elixir", @script, scenario]
    })
  end

  defp collect_until_result(handle, acc \\ []) do
    receive do
      {:agent_event, ^handle, {:result, result}} -> {Enum.reverse(acc), result}
      {:agent_event, ^handle, event} -> collect_until_result(handle, [event | acc])
    after
      15_000 -> flunk("no result; events so far: #{inspect(Enum.reverse(acc))}")
    end
  end

  test "happy path: handshake, chunks, tool call, usage result", ctx do
    use_scenario("happy")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Do the thing")
    {events, result} = collect_until_result(handle)

    assert {:session_started, "fake-sess-happy"} in events

    chunks = for {:message_chunk, text} <- events, do: text
    assert Enum.join(chunks) == "Working on it. Done."

    assert Enum.any?(events, fn
             {:tool_call, %{id: "tc-1", title: "Read README"}} -> true
             _other -> false
           end)

    assert result.status == :ok
    assert result.session_id == "fake-sess-happy"
    assert result.usage.prompt_tokens == 100
    assert result.usage.completion_tokens == 40
    assert result.usage.total_tokens == 140
  end

  test "agent writes a file through the client fs capability", ctx do
    use_scenario("writes_file")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Write hello")
    {_events, result} = collect_until_result(handle)

    assert result.status == :ok

    assert File.read!(Path.join(ctx.context.path, "hello.txt")) ==
             "hello from the fake agent\n"
  end

  test "out-of-sandbox permission request escalates and respects the human decision", ctx do
    use_scenario("permission")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Try something naughty")

    assert_receive {:agent_event, ^handle, {:permission_request, %{id: id, detail: detail}}},
                   15_000

    assert detail =~ "Delete /etc/passwd"

    :ok = Acp.answer_permission(handle, id, false)

    {events, result} = collect_until_result(handle)
    chunks = for {:message_chunk, text} <- events, do: text
    assert Enum.join(chunks) =~ ~s(reject)
    assert result.status == :ok
  end

  test "terminal round trip through the client", ctx do
    use_scenario("terminal")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Run a command")
    {events, result} = collect_until_result(handle)

    chunks = for {:message_chunk, text} <- events, do: text
    assert Enum.join(chunks) =~ "terminal-says-hi"
    assert result.status == :ok
  end

  test "agent crash mid-prompt yields an error result, not silence", ctx do
    use_scenario("crash")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Crash please")
    {events, result} = collect_until_result(handle)

    assert Enum.any?(events, &match?({:message_chunk, "about to crash"}, &1))
    assert result.status == :error
    assert result.content =~ "exited with status 3"
  end

  test "a stored session id is resumed via session/load", ctx do
    use_scenario("resume")

    task = put_context!(ctx.task, acp_session_id: "prior-sess-1")

    {:ok, handle} = Acp.start_run(task, ctx.agent, ctx.context, "Continue")
    {events, result} = collect_until_result(handle)

    assert {:session_started, "prior-sess-1"} in events
    chunks = for {:message_chunk, text} <- events, do: text
    assert Enum.join(chunks) =~ "continuing where we left off"
    assert result.status == :ok
    assert result.session_id == "prior-sess-1"
  end

  test "cancel emits a cancelled result", ctx do
    use_scenario("permission")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Slow work")
    assert_receive {:agent_event, ^handle, {:permission_request, _detail}}, 15_000

    ref = Process.monitor(handle)
    :ok = Acp.cancel(handle)

    assert_receive {:agent_event, ^handle, {:result, %{status: :cancelled}}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^handle, :normal}, 5_000
  end

  test "unknown harness command fails to start", ctx do
    Application.put_env(:code_lead, :harnesses, %{})

    Process.flag(:trap_exit, true)

    assert {:error, {:unknown_harness, :claude_code}} =
             Acp.start_run(ctx.task, ctx.agent, ctx.context, "hi")
  end
end
