defmodule CodeLead.Runtime.TaskRunner do
  @moduledoc """
  One GenServer per active task run. Provisions the execution context,
  starts the agent through its driver, consumes the normalized event
  stream (persisting the transcript, broadcasting over PubSub,
  maintaining attention and the audit trail), records usage, and drives
  the task's run-state transitions. Task state is derived from protocol
  events, never agent self-report.

  PubSub on `"task:<id>"`: `{:task_event, task_id, event}` for signals
  (live message deltas, attention, run lifecycle) and `{:agent_feed,
  task_id, row}` — broadcast by `CodeLead.AgentFeed` — for transcript
  rows. Board notifications (`{:board_changed, project_id, task_id}` on
  `"project:<id>"`) are broadcast by `CodeLead.Tasks` on every task
  write, so this runner never broadcasts them itself.

  Message chunks accumulate into one `streaming: true` transcript row,
  rewritten on a short debounce, and that row is always finalized
  before any other row is written — so row id order is display order and
  a reader joining mid-message sees the text so far.
  """

  use GenServer, restart: :temporary

  alias CodeLead.AgentDriver
  alias CodeLead.AgentFeed
  alias CodeLead.Agents
  alias CodeLead.Costs
  alias CodeLead.Executor
  alias CodeLead.Git
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task

  # How often the open message row is rewritten while chunks stream in.
  @flush_interval_ms 400

  # Tool input is echoed into the transcript, so it is truncated and
  # redacted first — a command line can carry a project env secret.
  @input_preview_limit 300

  # Git speaks English here — `CodeLead.Git` pins LC_ALL=C precisely so
  # these markers survive the operator's locale.
  @auth_markers [
    "Repository not found",
    "Authentication failed",
    "could not read Username",
    "terminal prompts disabled",
    "Permission denied (publickey)",
    "Invalid username or token"
  ]

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

  @doc """
  Renders a dispatch failure for the human reading the timeline. Every
  dispatch step funnels into one error clause, so the message has to
  carry which step failed and what to do about it.
  """
  @spec dispatch_error(term()) :: String.t()
  def dispatch_error({:executable_not_found, executable}) do
    "harness executable #{inspect(executable)} not found on PATH — install it " <>
      "where the CodeLead server can see it, then retry"
  end

  def dispatch_error({:unknown_harness, harness}) do
    "no launch command configured for harness #{inspect(harness)}"
  end

  def dispatch_error(
        {:provision, {:remote, %{output: output, forge: forge, token_present?: present?}}}
      ) do
    detail = Git.failure_reason(output)

    cond do
      not String.contains?(output, @auth_markers) ->
        "could not prepare the workspace: #{detail}"

      forge == :other ->
        "could not access the repository; this remote has no token convention, so the " <>
          "server's own git credentials were used: #{detail}"

      present? ->
        {kind, owner, repo} = forge

        "the #{Git.token_var(kind)} in the project env store was rejected by " <>
          "#{Git.host(kind)} — check that it has not expired and grants access to " <>
          "#{owner}/#{repo}: #{detail}"

      true ->
        {kind, _owner, _repo} = forge

        "could not access the repository — add a #{Git.token_var(kind)} to the " <>
          "project env store: #{detail}"
    end
  end

  def dispatch_error({:provision, output}) when is_binary(output) do
    detail = Git.failure_reason(output)

    if String.contains?(output, @auth_markers) do
      "could not access the repository — add a GITHUB_TOKEN (or GITLAB_TOKEN) " <>
        "to the project env store: #{detail}"
    else
      "could not prepare the workspace: #{detail}"
    end
  end

  def dispatch_error({:provision, reason}) do
    "could not prepare the workspace: #{inspect(reason)}"
  end

  def dispatch_error(reason), do: inspect(reason)

  ## GenServer callbacks

  @impl GenServer
  def init(task_id) do
    Process.flag(:trap_exit, true)
    {:ok, %{task_id: task_id}, {:continue, :dispatch}}
  end

  @impl GenServer
  def handle_continue(:dispatch, %{task_id: task_id}) do
    task = Tasks.get_task!(task_id)

    agent = Agents.get_agent!(task.agent_id)
    driver = AgentDriver.impl(agent)

    # Preflight before provisioning: a missing harness binary should not
    # cost a full repository clone first.
    with {:ok, task} <- Tasks.begin_dispatch(task),
         :ok <- driver.preflight(agent),
         {:ok, context} <- provision(task),
         task = Tasks.get_task!(task.id),
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

      AgentFeed.record_event(task.id, %{
        kind: :run_started,
        task_step_id: step.id,
        text: "#{agent.name} started"
      })

      broadcast_event(task, {:run_started, agent.name})

      {:noreply,
       %{
         task: task,
         agent: agent,
         context: context,
         driver: driver,
         handle: handle,
         task_step: step,
         started_at: DateTime.utc_now(:second),
         monotonic_start: now_ms(),
         live_usage: nil,
         open_row: nil,
         tool_rows: %{},
         permission_rows: %{}
       }}
    else
      {:error, reason} ->
        fail(task, nil, "dispatch failed: #{dispatch_error(reason)}")
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

      state =
        if reply == :ok do
          {:ok, _task} = Tasks.clear_attention(Tasks.get_task!(state.task.id))
          resolve_permission(state, to_string(request_id), granted?)
        else
          state
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
    state = finalize_open_row(state)
    task = Tasks.get_task!(state.task.id)
    fail(task, state, "agent driver crashed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Safety net for a killed runner: an unfinalized message row would
  # otherwise stay flagged as streaming forever.
  @impl GenServer
  def terminate(_reason, %{open_row: _open} = state) do
    finalize_open_row(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Normalized agent events

  # The live delta keeps the UI smooth; the row it accumulates into is
  # rewritten on a debounce so a reader joining mid-message sees it.
  defp handle_agent_event({:message_chunk, text} = event, state) do
    broadcast_event(state.task, event)
    {:noreply, append_open_row(state, text)}
  end

  # No task-topic broadcast: the transcript row is the only consumer.
  defp handle_agent_event({:tool_call, detail}, state) do
    state = finalize_open_row(state)
    {:noreply, record_tool_call(state, detail)}
  end

  # Advisory: no transcript row, no task write — it only feeds the live
  # cost readout, and is kept so a run that dies before its result can
  # still be costed.
  defp handle_agent_event({:usage, snapshot} = event, state) do
    broadcast_event(state.task, event)
    {:noreply, %{state | live_usage: snapshot}}
  end

  defp handle_agent_event({:session_started, session_id}, state) do
    {:ok, task} = Tasks.put_acp_session(Tasks.get_task!(state.task.id), session_id)
    {:noreply, %{state | task: task}}
  end

  defp handle_agent_event({:question, text} = event, state) do
    state = finalize_open_row(state)
    {:ok, task} = Tasks.set_attention(Tasks.get_task!(state.task.id), :agent_question, text)
    record_row(state, %{kind: :question, text: text})
    broadcast_event(task, event)
    {:noreply, state}
  end

  defp handle_agent_event({:permission_request, %{id: id, detail: detail}} = event, state) do
    state = finalize_open_row(state)
    ref = to_string(id)

    {:ok, task} =
      Tasks.set_attention(Tasks.get_task!(state.task.id), :permission_request, detail, ref: ref)

    row = record_row(state, %{kind: :permission, text: detail, external_id: ref})
    broadcast_event(task, event)
    {:noreply, %{state | permission_rows: Map.put(state.permission_rows, ref, row)}}
  end

  defp handle_agent_event({:result, result}, state) do
    state = finalize_open_row(state)
    task = Tasks.get_task!(state.task.id)
    duration_ms = elapsed_ms(state)
    usage = record_usage(state, result, duration_ms)
    maybe_write_llm_artifact(state, result)

    case result.status do
      :ok ->
        {:ok, task} = Tasks.complete_run(task)
        {:ok, task} = on_review_entry(task)

        record_row(state, %{
          kind: :result,
          text: result.content,
          data: run_meta(usage, duration_ms, "ok")
        })

        broadcast_event(task, {:run_completed, result})
        kick_queue_async()

      :error ->
        fail(task, state, result.content || "agent reported an error",
          record: false,
          meta: run_meta(usage, duration_ms, "error")
        )

      :cancelled ->
        record_row(state, %{kind: :result, data: run_meta(usage, duration_ms, "cancelled")})
        broadcast_event(task, {:run_cancelled, result})
    end

    {:stop, :normal, state}
  end

  # Unknown driver events must not take the run down with a
  # FunctionClauseError.
  defp handle_agent_event(_event, state), do: {:noreply, state}

  ## Transcript

  defp record_row(state, attrs) do
    AgentFeed.record_event(state.task.id, Map.put(attrs, :task_step_id, state.task_step.id))
  end

  defp append_open_row(%{open_row: nil} = state, text) do
    row = record_row(state, %{kind: :message, text: text, streaming: true})
    %{state | open_row: %{event: row, text: text, flushed_at: now_ms()}}
  end

  defp append_open_row(%{open_row: open} = state, chunk) do
    text = open.text <> chunk
    now = now_ms()

    if now - open.flushed_at >= @flush_interval_ms do
      row = AgentFeed.update_event(open.event, %{text: text})
      %{state | open_row: %{event: row, text: text, flushed_at: now}}
    else
      %{state | open_row: %{open | text: text}}
    end
  end

  defp finalize_open_row(%{open_row: nil} = state), do: state

  defp finalize_open_row(%{open_row: open} = state) do
    AgentFeed.update_event(open.event, %{text: open.text, streaming: false})
    %{state | open_row: nil}
  end

  defp record_tool_call(state, %{id: id} = detail) when is_binary(id) do
    case state.tool_rows[id] do
      nil ->
        row =
          record_row(state, %{
            kind: :tool_call,
            text: detail[:title],
            external_id: id,
            data: tool_data(detail)
          })

        %{state | tool_rows: Map.put(state.tool_rows, id, row)}

      row ->
        row = AgentFeed.update_event(row, %{text: detail[:title], data: tool_data(detail)})
        %{state | tool_rows: Map.put(state.tool_rows, id, row)}
    end
  end

  # A harness that omits toolCallId gets one row per update — nothing to
  # correlate on.
  defp record_tool_call(state, detail) do
    record_row(state, %{kind: :tool_call, text: detail[:title], data: tool_data(detail)})
    state
  end

  defp resolve_permission(state, ref, granted?) do
    case state.permission_rows[ref] do
      nil ->
        state

      row ->
        row = AgentFeed.update_event(row, %{data: %{"resolved" => granted?}})
        %{state | permission_rows: Map.put(state.permission_rows, ref, row)}
    end
  end

  defp tool_data(detail) do
    %{
      "status" => detail[:status],
      "tool_kind" => detail[:kind],
      "locations" => locations(detail[:locations]),
      "input" => input_summary(detail[:raw_input])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp locations(locations) when is_list(locations) do
    case Enum.flat_map(locations, &List.wrap(&1["path"])) do
      [] -> nil
      paths -> paths
    end
  end

  defp locations(_locations), do: nil

  # Kept field by field so the transcript can render a call the way a
  # human reads it (a description, then its command) instead of a JSON
  # blob. Only strings survive: it drops timeouts and other machinery,
  # and keeps the stored payload bounded.
  defp input_summary(input) when is_map(input) and map_size(input) > 0 do
    summary =
      for {key, value} <- input, is_binary(value), into: %{}, do: {key, preview_value(value)}

    if map_size(summary) == 0, do: nil, else: summary
  end

  defp input_summary(_input), do: nil

  # Redact before truncating: a token cut in half no longer matches the
  # patterns, and half a secret is still a secret.
  defp preview_value(value) do
    value
    |> Git.redact()
    |> String.slice(0, @input_preview_limit)
  end

  # Every terminal row carries the run's meta, whatever the outcome —
  # zeros where the driver reported nothing, never a missing key, so the
  # transcript card has something to render either way.
  defp run_meta(usage, duration_ms, status) do
    %{
      "status" => status,
      "tokens" => (usage && usage[:total_tokens]) || 0,
      "cost_cents" => (usage && usage[:cost_cents]) || 0,
      "duration_ms" => duration_ms
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp elapsed_ms(%{monotonic_start: start}), do: now_ms() - start
  defp elapsed_ms(_state), do: nil

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

  # Returns the priced usage so the caller can put the same numbers in
  # the transcript row it writes.
  defp record_usage(state, result, duration_ms) do
    usage = Costs.with_cost(result.usage || live_usage(state), state.agent.model_variant)

    Costs.record_run(%{
      task_id: state.task.id,
      task_step_id: state.task_step.id,
      agent_id: state.agent.id,
      provider_id: state.agent.provider_id,
      usage: usage,
      status: result.status,
      started_at: state.started_at,
      finished_at: DateTime.utc_now(:second),
      duration_ms: duration_ms
    })

    usage
  end

  # A run that crashed or was killed before its terminal result still
  # burned whatever the last mid-run snapshot reported.
  defp live_usage(%{live_usage: %{cost_cents: cents}}) when is_integer(cents) do
    %{
      prompt_tokens: 0,
      completion_tokens: 0,
      cached_read_tokens: 0,
      cached_write_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0,
      cost_cents: cents
    }
  end

  defp live_usage(_state), do: nil

  defp provision(task) do
    case Executor.impl().provision(task) do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, {:provision, reason}}
    end
  end

  defp fail(task, state, raw_detail, opts \\ []) do
    detail = Git.redact(raw_detail)

    case Tasks.fail_run(task, detail) do
      {:ok, task} ->
        meta =
          cond do
            opts[:meta] ->
              opts[:meta]

            state && Keyword.get(opts, :record, true) ->
              duration_ms = elapsed_ms(state)
              usage = record_usage(state, %{status: :error, usage: nil}, duration_ms)
              run_meta(usage, duration_ms, "error")

            true ->
              %{"status" => "error"}
          end

        # A dispatch failure has no run step yet, and is otherwise
        # invisible in the feed.
        AgentFeed.record_event(task.id, %{
          kind: :result,
          task_step_id: state && state.task_step.id,
          text: detail,
          data: meta
        })

        broadcast_event(task, {:run_failed, detail})

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
      Tasks.task_topic(task.id),
      {:task_event, task.id, event}
    )
  end
end
