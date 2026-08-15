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

    assert {:usage, %{cost_cents: 42, context_used: 340, context_size: 200_000}} in events

    assert result.status == :ok
    assert result.session_id == "fake-sess-happy"
    assert result.usage.prompt_tokens == 100
    assert result.usage.completion_tokens == 40
    assert result.usage.cached_read_tokens == 180
    assert result.usage.cached_write_tokens == 20
    assert result.usage.total_tokens == 340
    # The harness priced the run; Costs.with_cost/2 must not overwrite it.
    assert result.usage.cost_cents == 42
  end

  test "falls back to snake_case usage and leaves pricing to Costs", ctx do
    use_scenario("snake_usage")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Do the thing")
    {_events, result} = collect_until_result(handle)

    assert result.usage.prompt_tokens == 100
    assert result.usage.completion_tokens == 40
    assert result.usage.total_tokens == 140
    assert result.usage.cached_read_tokens == 0
    assert result.usage.cost_cents == nil
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

  test "a form elicitation surfaces as a structured question and unblocks on answer", ctx do
    use_scenario("elicitation")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Ask me something")

    assert_receive {:agent_event, ^handle, {:question, question}}, 15_000
    assert %{id: id, detail: "Which approach should I take?", tool_call_id: "tc-ask"} = question

    assert [select, custom, multi] = question.fields
    assert %{key: "question_0", label: "Approach", type: :select} = select
    assert Enum.map(select.options, & &1.value) == ["Refactor first", "Ship it"]
    assert %{key: "question_0_custom", type: :text, custom_for: "question_0"} = custom
    assert %{key: "question_1", type: :multi_select} = multi

    # The typed "Other" supersedes the selection, so the agent must never
    # see `question_0` alongside it.
    assert {:ok, content} =
             Acp.answer_question(handle, id, {
               :accept,
               %{
                 "question_0" => "Ship it",
                 "question_0_custom" => "Do neither",
                 "question_1" => ["api", "ui"]
               }
             })

    assert content == %{"question_0_custom" => "Do neither", "question_1" => ["api", "ui"]}

    {events, result} = collect_until_result(handle)
    chunks = for {:message_chunk, text} <- events, do: text
    answered = Enum.join(chunks)

    assert answered =~ ~s("action":"accept")
    assert answered =~ "Do neither"
    refute answered =~ "Ship it"
    assert result.status == :ok
  end

  test "a read-only context never offers the agent a way to ask", ctx do
    use_scenario("elicitation")
    context = %{ctx.context | read_only: true}

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, context, "Ask me something")
    {events, result} = collect_until_result(handle)

    chunks = for {:message_chunk, text} <- events, do: text
    assert Enum.join(chunks) == "no elicitation support"
    refute Enum.any?(events, &match?({:question, _question}, &1))
    assert result.status == :ok
  end

  test "cancelling a run settles a still-pending question", ctx do
    use_scenario("elicitation")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Ask me something")
    assert_receive {:agent_event, ^handle, {:question, _question}}, 15_000

    ref = Process.monitor(handle)
    :ok = Acp.cancel(handle)

    assert_receive {:agent_event, ^handle, {:result, %{status: :cancelled}}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^handle, :normal}, 5_000
  end

  test "answering a question that is not pending is refused", ctx do
    use_scenario("elicitation")

    {:ok, handle} = Acp.start_run(ctx.task, ctx.agent, ctx.context, "Ask me something")
    assert_receive {:agent_event, ^handle, {:question, %{id: id}}}, 15_000

    assert {:ok, _content} = Acp.answer_question(handle, id, :decline)
    assert {:error, :unknown_request} = Acp.answer_question(handle, id, :decline)

    {_events, result} = collect_until_result(handle)
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

  describe "preflight/2" do
    test "passes when the harness binary resolves", ctx do
      use_scenario("happy")
      assert Acp.preflight(ctx.agent, CodeLead.Executor.LocalSubprocess) == :ok
    end

    test "names a harness binary that is not installed", ctx do
      Application.put_env(:code_lead, :harnesses, %{claude_code: ["claude-agent-acp-missing"]})

      assert Acp.preflight(ctx.agent, CodeLead.Executor.LocalSubprocess) ==
               {:error, {:executable_not_found, "claude-agent-acp-missing"}}
    end

    test "reports an unconfigured harness", ctx do
      Application.put_env(:code_lead, :harnesses, %{})

      assert Acp.preflight(ctx.agent, CodeLead.Executor.LocalSubprocess) ==
               {:error, {:unknown_harness, :claude_code}}
    end
  end
end
