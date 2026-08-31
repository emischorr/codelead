defmodule CodeLead.AdvisoryRun do
  @moduledoc """
  An agent run in a **read-only, advisory posture**: it reads, it
  reports, it never lands work. Reviewers critiquing a diff and plan
  agents surveying a repository are the same primitive at two points in
  the lifecycle, so both go through here rather than each growing its
  own run loop.

  What this is *not* is the executor path. An advisory run has no
  `run_state` and writes no `agent_events` transcript; the caller owns
  its rows — including its `CodeLead.Runtime.LiveRuns` registration,
  which the caller claims *before* doing any work so the key's
  uniqueness can refuse a duplicate run. It is a blocking call that
  consumes the driver's event stream and returns the terminal result.

  ## Caller obligations

  `AgentDriver.Acp.start_run/4` is a `GenServer.start_link`, so the
  caller is **linked** to the driver process. Every caller must
  therefore be an isolated supervised child (`CodeLead.TaskSupervisor`)
  or trap exits — otherwise a crashing harness takes the caller with it.

  ## Cancellation

  An `:advisory_cancel` message — sent by
  `CodeLead.Runtime.LiveRuns.cancel_advisory/1` when a human decision
  supersedes pending advisory output — cancels the driver run and
  returns `{:error, :cancelled}`, so the caller still records its rows.
  Cancelling by killing the caller instead would take the linked driver
  down rows-unrecorded; never do that.

  ## Escalations

  A question or a permission request raises the ordinary `attention`
  field on the task, tagged `source: :advisory`, and the run keeps
  waiting. Neither is answerable for an advisory run today — the
  registry now *finds* the run, but the UI's Allow/Deny and Answer
  still route into the executor's `TaskRunner` — so `:timeout` is what
  ends a run that blocks on one. Surfacing it is still strictly better
  than the silent drop it replaces. The `:advisory` tag also keeps it
  out of `CodeLead.Tasks.Attention.blocks_agent?/1`: nothing is
  actually stuck waiting on an executor here, so it shouldn't raise
  the hand icon.

  A question is in practice unreachable here: an advisory run provisions
  a read-only context, and the ACP driver only advertises the elicitation
  capability for writable ones, so the harness keeps its ask-the-human
  tool disabled. The branch stays for drivers that escalate by other
  means.
  """

  alias CodeLead.AgentDriver
  alias CodeLead.Agents.Agent
  alias CodeLead.Executor.Context
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task

  @default_timeout :timer.minutes(15)

  @doc """
  Runs `agent` against `prompt` and blocks until the driver reports a
  terminal result.

  `context` is `nil` for drivers that need no filesystem. `:timeout`
  (default 15 minutes) is a deadline for the whole run, not for a
  single event — a chatty agent cannot postpone it indefinitely.
  """
  @spec run(Task.t(), Agent.t(), Context.t() | nil, AgentDriver.prompt(), keyword()) ::
          {:ok, AgentDriver.result()} | {:error, term()}
  def run(%Task{} = task, %Agent{} = agent, context, prompt, opts \\ []) do
    driver = AgentDriver.impl(agent)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @default_timeout)

    with :ok <- driver.preflight(agent, context_executor(context)),
         {:ok, handle} <- driver.start_run(task, agent, context, prompt) do
      await(handle, driver, task.id, deadline, "")
    end
  end

  # A nil context (llm_api) launches nothing; a built one names its own
  # executor — the caller decided (reviewers follow the task, surveys
  # stay local).
  defp context_executor(nil), do: CodeLead.Executor.impl()
  defp context_executor(%Context{executor: executor}), do: executor

  # Streamed chunks are accumulated because a driver may report its
  # final text only as chunks, leaving `result.content` nil.
  defp await(handle, driver, task_id, deadline, content_acc) do
    receive do
      {:agent_event, ^handle, {:result, result}} ->
        {:ok,
         Map.update(result, :content, content_acc, fn
           nil -> content_acc
           content -> content
         end)}

      {:agent_event, ^handle, {:message_chunk, text}} ->
        await(handle, driver, task_id, deadline, content_acc <> text)

      # Deliberately raised without a `ref`: nothing routes an answer
      # into an advisory run yet — the registry finds it, but Answer
      # targets the executor's TaskRunner — so an answerable card would
      # have nothing real to submit to.
      {:agent_event, ^handle, {:question, %{detail: detail}}} ->
        raise_attention(task_id, :agent_question, detail, nil)
        await(handle, driver, task_id, deadline, content_acc)

      {:agent_event, ^handle, {:permission_request, %{id: id, detail: detail}}} ->
        raise_attention(task_id, :permission_request, detail, to_string(id))
        await(handle, driver, task_id, deadline, content_acc)

      {:agent_event, ^handle, _other} ->
        await(handle, driver, task_id, deadline, content_acc)

      :advisory_cancel ->
        driver.cancel(handle)
        {:error, :cancelled}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        driver.cancel(handle)
        {:error, :timeout}
    end
  end

  defp raise_attention(task_id, type, detail, ref) do
    {:ok, _task} =
      Tasks.set_attention(Tasks.get_task!(task_id), type, detail, :advisory, ref: ref)

    :ok
  end
end
