defmodule CodeLead.AdvisoryRun do
  @moduledoc """
  An agent run in a **read-only, advisory posture**: it reads, it
  reports, it never lands work. Reviewers critiquing a diff and plan
  agents surveying a repository are the same primitive at two points in
  the lifecycle, so both go through here rather than each growing its
  own run loop.

  What this is *not* is the executor path. An advisory run has no
  `run_state`, is not registered in `CodeLead.Runtime.Registry`, and
  writes no `agent_events` transcript; the caller owns its rows. It is
  a blocking call that consumes the driver's event stream and returns
  the terminal result.

  ## Caller obligations

  `AgentDriver.Acp.start_run/4` is a `GenServer.start_link`, so the
  caller is **linked** to the driver process. Every caller must
  therefore be an isolated supervised child (`CodeLead.TaskSupervisor`)
  or trap exits — otherwise a crashing harness takes the caller with it.

  ## Escalations

  A question or a permission request raises the ordinary `attention`
  field on the task and the run keeps waiting. Neither is answerable
  for an advisory run today — the UI's Allow/Deny and Answer route
  through `CodeLead.Runtime`, which only finds executor runs — so
  `:timeout` is what ends a run that blocks on one. Surfacing it is
  still strictly better than the silent drop it replaces.

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

    with :ok <- driver.preflight(agent),
         {:ok, handle} <- driver.start_run(task, agent, context, prompt) do
      await(handle, driver, task.id, deadline, "")
    end
  end

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

      # Deliberately raised without a `ref`: an advisory run is not in the
      # registry, so an answerable card would have nothing to submit to.
      {:agent_event, ^handle, {:question, %{detail: detail}}} ->
        raise_attention(task_id, :agent_question, detail, nil)
        await(handle, driver, task_id, deadline, content_acc)

      {:agent_event, ^handle, {:permission_request, %{id: id, detail: detail}}} ->
        raise_attention(task_id, :permission_request, detail, to_string(id))
        await(handle, driver, task_id, deadline, content_acc)

      {:agent_event, ^handle, _other} ->
        await(handle, driver, task_id, deadline, content_acc)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        driver.cancel(handle)
        {:error, :timeout}
    end
  end

  defp raise_attention(task_id, type, detail, ref) do
    {:ok, _task} = Tasks.set_attention(Tasks.get_task!(task_id), type, detail, ref: ref)
    :ok
  end
end
