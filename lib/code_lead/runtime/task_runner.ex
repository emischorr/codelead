defmodule CodeLead.Runtime.TaskRunner do
  @moduledoc """
  One GenServer per active task run. Provisions the execution context,
  starts the agent through its driver, consumes the normalized event
  stream (broadcasting over PubSub, maintaining attention and the audit
  trail), records usage, and drives the task's run-state transitions.
  Task state is derived from protocol events, never agent self-report.

  PubSub: events go to `"task:<id>"` as `{:task_event, task_id, event}`;
  board-affecting changes additionally go to `"project:<id>"` as
  `{:board_changed, project_id, task_id}`.
  """

  use GenServer, restart: :temporary

  alias CodeLead.AgentDriver
  alias CodeLead.Agents
  alias CodeLead.Costs
  alias CodeLead.Executor
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task

  @spec start_link(pos_integer()) :: GenServer.on_start()
  def start_link(task_id) do
    GenServer.start_link(__MODULE__, task_id, name: RunSupervisor.via(task_id))
  end

  @doc """
  Cancels the running agent (driver-level); the workflow transition is
  the caller's job.
  """
  @spec cancel(pos_integer()) :: :ok | {:error, :not_running}
  def cancel(task_id) do
    case RunSupervisor.whereis(task_id) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, :cancel)
    end
  end

  @doc """
  Answers a surfaced permission escalation of the running agent.
  """
  @spec answer_permission(pos_integer(), term(), boolean()) :: :ok | {:error, term()}
  def answer_permission(task_id, request_id, granted?) do
    case RunSupervisor.whereis(task_id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:answer_permission, request_id, granted?})
    end
  end

  ## GenServer callbacks

  @impl GenServer
  def init(task_id) do
    Process.flag(:trap_exit, true)
    {:ok, %{task_id: task_id}, {:continue, :dispatch}}
  end

  @impl GenServer
  def handle_continue(:dispatch, %{task_id: task_id}) do
    task = Tasks.get_task!(task_id)

    with {:ok, task} <- Tasks.begin_dispatch(task),
         {:ok, context} <- Executor.impl().provision(task),
         task = Tasks.get_task!(task.id),
         agent = Agents.get_agent!(task.agent_id),
         driver = AgentDriver.impl(agent),
         {:ok, handle} <- driver.start_run(task, agent, context, build_prompt(task)),
         {:ok, task} <- Tasks.mark_executing(task) do
      step =
        Tasks.record_step(
          task.id,
          :run,
          :agent,
          agent.name,
          "run started",
          Integer.to_string(agent.id)
        )

      broadcast_board(task)
      broadcast_event(task, {:run_started, agent.name})

      {:noreply,
       %{
         task: task,
         agent: agent,
         context: context,
         driver: driver,
         handle: handle,
         task_step: step,
         started_at: DateTime.utc_now(:second)
       }}
    else
      {:error, reason} ->
        fail(task, nil, "dispatch failed: #{inspect(reason)}")
        {:stop, :normal, %{task_id: task_id}}
    end
  end

  @impl GenServer
  def handle_cast(:cancel, state) do
    state.driver.cancel(state.handle)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:answer_permission, request_id, granted?}, _from, state) do
    if function_exported?(state.driver, :answer_permission, 3) do
      reply = state.driver.answer_permission(state.handle, request_id, granted?)

      if reply == :ok do
        {:ok, task} = Tasks.clear_attention(Tasks.get_task!(state.task.id))
        broadcast_board(task)
      end

      {:reply, reply, state}
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  @impl GenServer
  def handle_info({:agent_event, handle, event}, %{handle: handle} = state) do
    handle_agent_event(event, state)
  end

  def handle_info({:agent_event, _stale, _event}, state), do: {:noreply, state}

  def handle_info({:EXIT, handle, reason}, %{handle: handle} = state)
      when reason != :normal do
    task = Tasks.get_task!(state.task.id)
    fail(task, state, "agent driver crashed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Normalized agent events

  defp handle_agent_event({:message_chunk, _text} = event, state) do
    broadcast_event(state.task, event)
    {:noreply, state}
  end

  defp handle_agent_event({:tool_call, _detail} = event, state) do
    broadcast_event(state.task, event)
    {:noreply, state}
  end

  defp handle_agent_event({:session_started, session_id}, state) do
    {:ok, task} = Tasks.put_acp_session(Tasks.get_task!(state.task.id), session_id)
    {:noreply, %{state | task: task}}
  end

  defp handle_agent_event({:question, text} = event, state) do
    {:ok, task} = Tasks.set_attention(Tasks.get_task!(state.task.id), :agent_question, text)
    broadcast_event(task, event)
    broadcast_board(task)
    {:noreply, state}
  end

  defp handle_agent_event({:permission_request, %{detail: detail}} = event, state) do
    {:ok, task} =
      Tasks.set_attention(Tasks.get_task!(state.task.id), :permission_request, detail)

    broadcast_event(task, event)
    broadcast_board(task)
    {:noreply, state}
  end

  defp handle_agent_event({:result, result}, state) do
    task = Tasks.get_task!(state.task.id)
    record_usage(state, result)
    maybe_write_llm_artifact(state, result)

    case result.status do
      :ok ->
        {:ok, task} = Tasks.complete_run(task)
        {:ok, task} = on_review_entry(task)
        broadcast_event(task, {:run_completed, result})
        broadcast_board(task)
        kick_queue_async()

      :error ->
        fail(task, state, result.content || "agent reported an error", record: false)

      :cancelled ->
        broadcast_event(task, {:run_cancelled, result})
    end

    {:stop, :normal, state}
  end

  ## Internals

  defp on_review_entry(task) do
    {:ok, _cycle} = CodeLead.Reviews.start_cycle(task)
    {:ok, task}
  end

  defp build_prompt(%Task{next_prompt: feedback}) when is_binary(feedback), do: feedback

  defp build_prompt(%Task{} = task) do
    """
    # #{task.title}

    #{task.description || ""}

    #{if task.spec, do: "## Spec / acceptance criteria\n\n#{task.spec}", else: ""}
    """
  end

  # An llm_api executor produces text, not files — persist it as the
  # task's artifact so review and Done have something to show.
  defp maybe_write_llm_artifact(%{agent: %{driver: :llm_api}, context: context}, %{
         status: :ok,
         content: content
       })
       when is_binary(content) do
    File.write!(Path.join(context.path, "output.md"), content)
  end

  defp maybe_write_llm_artifact(_state, _result), do: :ok

  defp record_usage(state, result) do
    Costs.record_run(%{
      task_id: state.task.id,
      task_step_id: state.task_step.id,
      agent_id: state.agent.id,
      provider_id: state.agent.provider_id,
      usage: Costs.with_cost(result.usage, state.agent.model_variant),
      status: result.status,
      started_at: state.started_at,
      finished_at: DateTime.utc_now(:second)
    })
  end

  defp fail(task, state, detail, opts \\ []) do
    case Tasks.fail_run(task, detail) do
      {:ok, task} ->
        if state && Keyword.get(opts, :record, true) do
          record_usage(state, %{status: :error, usage: nil})
        end

        broadcast_event(task, {:run_failed, detail})
        broadcast_board(task)

      {:error, :invalid_state} ->
        :ok
    end
  end

  defp kick_queue_async do
    Elixir.Task.Supervisor.start_child(CodeLead.TaskSupervisor, &CodeLead.Runtime.kick_queue/0)
  end

  defp broadcast_event(task, event) do
    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      "task:#{task.id}",
      {:task_event, task.id, event}
    )
  end

  defp broadcast_board(task) do
    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      "project:#{task.project_id}",
      {:board_changed, task.project_id, task.id}
    )
  end
end
