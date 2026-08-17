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
  a reader joining mid-message sees the text so far. A row finalized by a
  tool call stays reopenable for a short window, because a background
  subagent's tool calls interleave with the parent's streaming text and
  must not split one message across two rows.
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

  # How long a tool-call-closed message row stays reopenable. A real turn
  # boundary waits for a tool round trip plus model latency; a background
  # subagent's tool call lands between two chunks of one sentence.
  @default_resume_window_ms 500

  # Tool input is echoed into the transcript, so it is truncated and
  # redacted first — a command line can carry a project env secret.
  @input_preview_limit 300

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
  Answers, skips, or cancels a surfaced question of the running agent.
  """
  @spec answer_question(pos_integer(), term(), AgentDriver.question_answer()) ::
          :ok | {:error, term()}
  def answer_question(task_id, request_id, answer) do
    case RunSupervisor.whereis(task_id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:answer_question, request_id, answer})
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
    Git.remote_failure("prepare the workspace", output, forge, present?)
  end

  def dispatch_error({:provision, output}) when is_binary(output) do
    detail = output |> Git.failure_reason() |> Git.redact()

    if Git.refusal(output) == :other do
      "could not prepare the workspace: #{detail}"
    else
      "could not access the repository — add a GITHUB_TOKEN (or GITLAB_TOKEN) " <>
        "to the project env store: #{detail}"
    end
  end

  def dispatch_error({:provision, {:missing_execution_env, repo_name}}) do
    "this task is set to run in a container, but repository #{inspect(repo_name)} " <>
      "does not enable devcontainer execution — enable it in Settings → Project → " <>
      "Repositories (the repo needs a .devcontainer setup), or switch the task's " <>
      "execution back to Local"
  end

  def dispatch_error({:provision, {:missing_devcontainer_config, repo_name}}) do
    "repository #{inspect(repo_name)} enables devcontainer execution but carries no " <>
      "devcontainer configuration — add a .devcontainer/devcontainer.json to the repo " <>
      "(or fix the declared config path), or switch the task's execution back to Local"
  end

  def dispatch_error({:provision, :workspace_not_host_coincident}) do
    "container execution needs the data root bind-mounted from the host at the " <>
      "identical path (DATA_ROOT) — a named workspace volume (WORKSPACE_VOLUME) or a " <>
      "HOST_DATA_ROOT bind cannot work with devcontainers, because the host daemon " <>
      "resolves the repo's own workspace mounts host-side; see docs/deployment.md"
  end

  def dispatch_error({:provision, {:devcontainer_up_failed, message, tail}}) do
    "could not bring the task's devcontainer up: #{Git.redact(message)}" <>
      if(tail == "", do: "", else: " — log tail: #{Git.redact(tail)}")
  end

  def dispatch_error({:provision, {:docker_unreachable, output}}) do
    dispatch_error({:docker_unreachable, output})
  end

  def dispatch_error({:docker_unreachable, _output}) do
    "the Docker daemon is unreachable — is `/var/run/docker.sock` mounted into the " <>
      "CodeLead container? A stack whose app container predates the mount picks it " <>
      "up with `docker compose up -d`; see docs/deployment.md"
  end

  def dispatch_error({:provision, {:docker_permission_denied, output}}) do
    dispatch_error({:docker_permission_denied, output})
  end

  def dispatch_error({:docker_permission_denied, _output}) do
    "CodeLead cannot use the mounted docker socket — the entrypoint normally grants " <>
      "socket access at start, so either the socket appeared after boot (restart the " <>
      "stack) or the container runs with a `user:` override, which takes that back: " <>
      "add the host docker group's id via `group_add` (see docs/deployment.md)"
  end

  def dispatch_error(:docker_cli_not_found) do
    "the docker CLI is not installed where CodeLead runs — container execution needs it"
  end

  def dispatch_error(:devcontainer_cli_not_found) do
    "the devcontainer CLI is not installed where CodeLead runs — container execution " <>
      "needs it (npm i -g @devcontainers/cli; the published image ships it)"
  end

  def dispatch_error({:harness_not_staged, detail}) do
    "the container harness is not staged (#{detail}) — HARNESS_VERSION resolves at " <>
      "boot (default pinned in runtime.exs); set it, or HARNESS_SOURCE, and restart"
  end

  def dispatch_error({:libc_probe_failed, output}) do
    "could not detect the task image's libc: #{Git.redact(output)} — the declared " <>
      "container image must provide `sh`"
  end

  def dispatch_error({:harness_build_failed, output}) do
    "could not build the container harness: #{Git.redact(output)} — the build container " <>
      "needs network access to the npm registry through docker; check connectivity and " <>
      "retry, or set HARNESS_SOURCE to a pre-built binary as a manual override"
  end

  def dispatch_error({:container_command_unsupported, command}) do
    "#{inspect(command)} cannot run in a container yet — container execution currently " <>
      "supports the Claude Code harness only; switch the task to Local or pick a " <>
      "Claude Code agent"
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
         :ok <- driver.preflight(agent, Executor.for_task(task)),
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
         resumable_row: nil,
         tool_rows: %{},
         permission_rows: %{},
         question_rows: %{}
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
          state |> resolve_permission(to_string(request_id), granted?) |> refresh_attention()
        else
          state
        end

      {:reply, reply, state}
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:answer_question, request_id, answer}, _from, state) do
    if function_exported?(state.driver, :answer_question, 3) do
      case state.driver.answer_question(state.handle, request_id, answer) do
        {:ok, content} ->
          state =
            state
            |> resolve_question(to_string(request_id), answer, content)
            |> refresh_attention()

          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
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
  # The row is closed but kept reopenable: tool calls from a background
  # subagent interleave with the parent's still-streaming text, and those
  # must not split one message into two rows.
  defp handle_agent_event({:tool_call, detail}, state) do
    state = finalize_open_row(state, resumable: true)
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

  # The agent is blocked on this until a human answers, so the run stays
  # in Running rather than reaching the automatic completion edge.
  defp handle_agent_event({:question, %{id: id, detail: detail, fields: fields}} = event, state) do
    state = finalize_open_row(state)
    ref = to_string(id)

    {:ok, task} =
      Tasks.set_attention(Tasks.get_task!(state.task.id), :agent_question, detail, ref: ref)

    row =
      record_row(state, %{
        kind: :question,
        text: detail,
        external_id: ref,
        data: %{"fields" => Enum.map(fields, &question_field_data/1)}
      })

    broadcast_event(task, event)
    {:noreply, %{state | question_rows: Map.put(state.question_rows, ref, row)}}
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
        # The workflow's one automatic edge; entering the Review stage
        # is what fans the reviewers out.
        {:ok, task} = CodeLead.Runtime.complete_run(task)

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
    case resume_candidate(state) do
      nil ->
        row = record_row(state, %{kind: :message, text: text, streaming: true})
        open_row(state, row, text)

      %{event: event, text: previous} ->
        text = previous <> text
        row = AgentFeed.update_event(event, %{text: text, streaming: true})
        open_row(state, row, text)
    end
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

  defp open_row(state, row, text) do
    %{
      state
      | open_row: %{event: row, text: text, flushed_at: now_ms()},
        resumable_row: nil
    }
  end

  # A row closed by a tool call may still be continued; one closed by a
  # question, permission, result or shutdown never is — text after those
  # is a new message.
  defp finalize_open_row(state, opts \\ [])

  defp finalize_open_row(%{open_row: nil} = state, opts) do
    if opts[:resumable], do: state, else: %{state | resumable_row: nil}
  end

  defp finalize_open_row(%{open_row: open} = state, opts) do
    row = AgentFeed.update_event(open.event, %{text: open.text, streaming: false})

    resumable =
      if opts[:resumable],
        do: %{event: row, text: open.text, closed_at: now_ms()}

    %{state | open_row: nil, resumable_row: resumable}
  end

  defp resume_candidate(%{resumable_row: %{closed_at: closed_at} = resumable}) do
    if now_ms() - closed_at < resume_window_ms(), do: resumable
  end

  defp resume_candidate(_state), do: nil

  defp resume_window_ms do
    Application.get_env(:code_lead, :message_resume_window_ms, @default_resume_window_ms)
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

  defp resolve_question(state, ref, answer, content) do
    case state.question_rows[ref] do
      nil ->
        state

      row ->
        row =
          AgentFeed.update_event(row, %{
            data: %{"resolved" => resolution(answer), "answers" => content}
          })

        %{state | question_rows: Map.put(state.question_rows, ref, row)}
    end
  end

  # `resolved` is a string here and a boolean on a permission row; both
  # are only ever tested for presence, which is what tells the UI the
  # escalation is settled.
  defp resolution({:accept, _values}), do: "answered"
  defp resolution(:decline), do: "skipped"
  defp resolution(:cancel), do: "cancelled"

  # Attention belongs to the oldest escalation still waiting, not to the
  # one just settled — a question and a permission request can be open at
  # the same time, and clearing wholesale would lose the other one.
  defp refresh_attention(state) do
    task = Tasks.get_task!(state.task.id)

    case next_pending(state) do
      nil -> {:ok, _task} = Tasks.clear_attention(task)
      {type, detail, ref} -> {:ok, _task} = Tasks.set_attention(task, type, detail, ref: ref)
    end

    state
  end

  defp next_pending(%{question_rows: question_rows, permission_rows: permission_rows}) do
    [{question_rows, :agent_question}, {permission_rows, :permission_request}]
    |> Enum.flat_map(fn {rows, type} ->
      for {_ref, row} <- rows, is_nil(row.data["resolved"]), do: {row.id, type, row}
    end)
    |> Enum.min_by(fn {id, _type, _row} -> id end, fn -> nil end)
    |> case do
      nil -> nil
      {_id, type, row} -> {type, row.text, row.external_id}
    end
  end

  # `data` lands in a jsonb column, and only its top level is stringified
  # on write — a nested atom key would render for live viewers and then
  # come back as a string on reload.
  defp question_field_data(field) do
    %{
      "key" => field.key,
      "label" => field.label,
      "description" => field.description,
      "type" => Atom.to_string(field.type),
      "required" => field.required?,
      "custom_for" => field.custom_for,
      "options" =>
        Enum.map(
          field.options,
          &%{"value" => &1.value, "label" => &1.label, "description" => &1.description}
        )
    }
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
    case Executor.for_task(task).provision(task) do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, {:provision, reason}}
    end
  end

  defp fail(task, state, raw_detail, opts \\ []) do
    detail = maybe_diagnose(task, state, Git.redact(raw_detail))

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

  # A started container run that dies can have a container-shaped cause
  # (removed externally, exited); the executor can tell, the exit status
  # cannot. Dispatch failures pass `state = nil` and are not enriched —
  # a provision error would only produce "no container" noise.
  defp maybe_diagnose(%Task{execution_env: :container} = task, state, detail)
       when not is_nil(state) do
    executor = Executor.for_task(task)

    with true <- function_exported?(executor, :diagnose, 1),
         {:ok, extra} <- executor.diagnose(task.id) do
      detail <> " — " <> extra
    else
      _running_or_unsupported -> detail
    end
  end

  defp maybe_diagnose(_task, _state, detail), do: detail

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
