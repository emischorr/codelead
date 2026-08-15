defmodule CodeLead.AgentDriver.Acp do
  @moduledoc """
  ACP driver: launches a coding harness (Claude Code / Codex) as an
  Agent Client Protocol subprocess inside the execution context and
  drives one prompt turn. CodeLead is the ACP client and owns the
  filesystem, terminal, and permission decisions.

  One GenServer per run: it owns the `Acp.Connection`, performs the
  handshake (`initialize` → `session/new` or `session/load` when the
  task carries a resumable session), sends `session/prompt`, translates
  protocol traffic into the normalized `CodeLead.AgentDriver` event
  stream, and stops after emitting the terminal `{:result, ...}`.

  Additional event: `{:session_started, session_id}` right after the
  session exists — the runner persists it for later resume.

  ## Permission policy

  Inside the sandbox (all tool-call locations under the context path,
  or no location info) requests are auto-granted — the human gate is at
  the workflow level. Requests touching paths outside the sandbox are
  surfaced as `{:permission_request, %{id:, detail:}}` events and stay
  pending until `answer_permission/3`.

  ## Asking the human

  The client advertises the `elicitation` form capability, which is what
  makes a harness offer its ask-the-human tool at all — Claude Code's
  adapter removes that tool from the model's toolset unless the capability
  is present. An `elicitation/create` request is surfaced as
  `{:question, %{id:, detail:, fields:, tool_call_id:}}` (normalized by
  `CodeLead.Acp.Elicitation`) and left unanswered on the wire, which
  blocks the agent's prompt turn until `answer_question/3` — deliberately
  without a timeout, since waiting for the human is the point.

  The capability is withheld for a read-only context. Advisory runs
  (reviewers, planning surveys) are blocking calls with no way to route
  an answer back, so a question there could only hang until their own
  deadline.

  ## Terminal support (MVP)

  `terminal/create` runs the command to completion under
  `CodeLead.TaskSupervisor`; `terminal/output` returns the full output
  once finished (empty while running), `terminal/wait_for_exit` blocks
  until done, `terminal/kill` terminates the task.
  """

  @behaviour CodeLead.AgentDriver

  use GenServer, restart: :temporary

  alias CodeLead.Acp.Connection
  alias CodeLead.Acp.Elicitation
  alias CodeLead.AgentDriver
  alias CodeLead.Agents
  alias CodeLead.Executor.Context
  alias CodeLead.Executor.EnvScrub

  ## AgentDriver callbacks

  @impl CodeLead.AgentDriver
  def preflight(agent, executor) do
    with {:ok, command} <- harness_command(agent) do
      executor.available?(command)
    end
  end

  @impl CodeLead.AgentDriver
  def start_run(task, agent, %Context{} = context, prompt) do
    GenServer.start_link(__MODULE__, %{
      caller: self(),
      task: task,
      agent: agent,
      context: context,
      prompt: prompt
    })
  end

  @impl CodeLead.AgentDriver
  def send_message(handle, message) do
    GenServer.call(handle, {:send_message, message})
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @impl CodeLead.AgentDriver
  def cancel(handle) do
    GenServer.cast(handle, :cancel)
    :ok
  end

  @doc """
  Resolves a surfaced permission escalation.
  """
  @spec answer_permission(pid(), term(), boolean()) :: :ok | {:error, :unknown_request}
  def answer_permission(handle, request_id, granted?) do
    GenServer.call(handle, {:answer_permission, request_id, granted?})
  end

  @doc """
  Settles a surfaced agent question, unblocking the prompt turn.

  Returns the content the agent actually received, so the caller can
  record the answer exactly as sent — coercion and the "Other" override
  are applied here, not by the caller.
  """
  @spec answer_question(pid(), term(), AgentDriver.question_answer()) ::
          {:ok, map()} | {:error, :unknown_request | :not_running}
  def answer_question(handle, request_id, answer) do
    GenServer.call(handle, {:answer_question, request_id, answer})
  catch
    :exit, _reason -> {:error, :not_running}
  end

  ## GenServer callbacks

  @impl GenServer
  def init(%{caller: caller, task: task, agent: agent, context: context, prompt: prompt}) do
    with {:ok, command} <- harness_command(agent),
         {:ok, conn} <- open_connection(agent, context, command) do
      ref = Connection.request(conn, "initialize", initialize_params(not context.read_only))

      {:ok,
       %{
         caller: caller,
         conn: conn,
         context: context,
         prompt: prompt,
         session_id: task.acp_session_id,
         stage: {:initializing, ref},
         pending_permissions: %{},
         pending_questions: %{},
         terminals: %{},
         usage: nil,
         cost_cents: nil,
         context_used: nil,
         context_size: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send_message, _message}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:answer_permission, request_id, granted?}, _from, state) do
    case Map.pop(state.pending_permissions, to_string(request_id)) do
      {nil, _pending} ->
        {:reply, {:error, :unknown_request}, state}

      {{original_id, options}, pending} ->
        Connection.respond(state.conn, original_id, permission_outcome(options, granted?))
        {:reply, :ok, %{state | pending_permissions: pending}}
    end
  end

  def handle_call({:answer_question, request_id, answer}, _from, state) do
    case Map.pop(state.pending_questions, to_string(request_id)) do
      {nil, _pending} ->
        {:reply, {:error, :unknown_request}, state}

      {{original_id, fields}, pending} ->
        content = question_content(fields, answer)
        Connection.respond(state.conn, original_id, question_outcome(content, answer))
        {:reply, {:ok, content}, %{state | pending_questions: pending}}
    end
  end

  @impl GenServer
  def handle_cast(:cancel, state) do
    if state.session_id do
      Connection.notify(state.conn, "session/cancel", %{sessionId: state.session_id})
    end

    finish(state, %{status: :cancelled, content: nil, usage: settled_usage(state)})
  end

  @impl GenServer
  def handle_info({:acp_response, ref, reply}, %{stage: {stage_name, ref}} = state) do
    handle_stage_response(stage_name, reply, state)
  end

  def handle_info({:acp_response, _stale_ref, _reply}, state), do: {:noreply, state}

  def handle_info({:acp_notification, "session/update", params}, state) do
    {:noreply, handle_session_update(params["update"] || %{}, state)}
  end

  def handle_info({:acp_notification, _method, _params}, state), do: {:noreply, state}

  def handle_info({:acp_request, id, method, params}, state) do
    handle_agent_request(method, id, params, state)
  end

  def handle_info({:acp_closed, exit_status}, state) do
    finish(state, %{
      status: :error,
      content: "agent process exited with status #{exit_status}",
      usage: settled_usage(state)
    })
  end

  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])
    {:noreply, complete_terminal(state, task_ref, result)}
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    {:noreply, complete_terminal(state, task_ref, {"terminal crashed: #{inspect(reason)}", 137})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Handshake stages

  defp handle_stage_response(:initializing, {:ok, result}, state) do
    load_supported? = get_in(result, ["agentCapabilities", "loadSession"]) == true

    if state.session_id && load_supported? do
      ref =
        Connection.request(state.conn, "session/load", %{
          sessionId: state.session_id,
          cwd: state.context.path,
          mcpServers: []
        })

      {:noreply, %{state | stage: {:loading_session, ref}}}
    else
      {:noreply, request_new_session(state)}
    end
  end

  defp handle_stage_response(:initializing, {:error, error}, state) do
    finish(state, %{status: :error, content: "initialize failed: #{inspect(error)}", usage: nil})
  end

  defp handle_stage_response(:loading_session, {:ok, _result}, state) do
    {:noreply, start_prompt(state)}
  end

  defp handle_stage_response(:loading_session, {:error, _error}, state) do
    # Resume unsupported or expired — fall back to a fresh session; the
    # request-changes feedback prompt carries the context forward.
    {:noreply, request_new_session(%{state | session_id: nil})}
  end

  defp handle_stage_response(:creating_session, {:ok, result}, state) do
    session_id = result["sessionId"]
    emit(state, {:session_started, session_id})
    {:noreply, start_prompt(%{state | session_id: session_id})}
  end

  defp handle_stage_response(:creating_session, {:error, error}, state) do
    finish(state, %{status: :error, content: "session/new failed: #{inspect(error)}", usage: nil})
  end

  defp handle_stage_response(:prompting, {:ok, result}, state) do
    usage = settled_usage(%{state | usage: extract_usage(result) || state.usage})

    status =
      case result["stopReason"] do
        "end_turn" -> :ok
        "cancelled" -> :cancelled
        other -> {:error_stop, other}
      end

    case status do
      {:error_stop, reason} ->
        finish(state, %{status: :error, content: "stopped: #{reason}", usage: usage})

      status ->
        finish(state, %{status: status, content: nil, usage: usage})
    end
  end

  defp handle_stage_response(:prompting, {:error, error}, state) do
    finish(state, %{
      status: :error,
      content: "prompt failed: #{inspect(error)}",
      usage: settled_usage(state)
    })
  end

  defp request_new_session(state) do
    ref =
      Connection.request(state.conn, "session/new", %{
        cwd: state.context.path,
        mcpServers: []
      })

    %{state | stage: {:creating_session, ref}}
  end

  defp start_prompt(state) do
    if state.session_id && state.stage |> elem(0) == :loading_session do
      emit(state, {:session_started, state.session_id})
    end

    ref =
      Connection.request(state.conn, "session/prompt", %{
        sessionId: state.session_id,
        prompt: [%{type: "text", text: prompt_text(state.prompt)}]
      })

    %{state | stage: {:prompting, ref}}
  end

  defp prompt_text(prompt) when is_binary(prompt), do: prompt

  defp prompt_text(prompt) when is_list(prompt) do
    Enum.map_join(prompt, "\n\n", fn %{role: role, content: content} -> "#{role}: #{content}" end)
  end

  ## Session updates → normalized events

  defp handle_session_update(%{"sessionUpdate" => "agent_message_chunk"} = update, state) do
    case update["content"] do
      %{"type" => "text", "text" => text} -> emit(state, {:message_chunk, text})
      _other -> :ok
    end

    state
  end

  # `tool_call` and `tool_call_update` share one normalized event; the
  # consumer correlates them by `id` and merges non-nil fields, since an
  # update usually carries only a status.
  defp handle_session_update(%{"sessionUpdate" => kind} = update, state)
       when kind in ["tool_call", "tool_call_update"] do
    emit(
      state,
      {:tool_call,
       %{
         id: update["toolCallId"],
         title: update["title"],
         kind: update["kind"],
         status: update["status"],
         locations: update["locations"],
         raw_input: update["rawInput"]
       }}
    )

    state
  end

  # The harness reports money as it goes: `cost.amount` is the session's
  # cumulative spend in `cost.currency`. One CodeLead run is one prompt
  # turn in a freshly spawned subprocess, so cumulative equals this run's
  # cost — no baseline to subtract. `used`/`size` are context-window
  # occupancy, not tokens billed.
  defp handle_session_update(%{"sessionUpdate" => "usage_update"} = update, state) do
    state = %{
      state
      | cost_cents: cost_cents(update["cost"]) || state.cost_cents,
        context_used: update["used"] || state.context_used,
        context_size: update["size"] || state.context_size
    }

    emit(
      state,
      {:usage,
       %{
         cost_cents: state.cost_cents,
         context_used: state.context_used,
         context_size: state.context_size
       }}
    )

    state
  end

  defp handle_session_update(_update, state), do: state

  ## Agent → client requests

  defp handle_agent_request("fs/read_text_file", id, params, state) do
    path = params["path"]

    with :ok <- check_sandbox(path, state.context.path),
         {:ok, content} <- File.read(path) do
      Connection.respond(state.conn, id, %{content: content})
    else
      {:error, reason} ->
        Connection.respond_error(state.conn, id, -32_000, "read failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp handle_agent_request(
         "fs/write_text_file",
         id,
         params,
         %{context: %{read_only: true}} = state
       ) do
    _ = params
    Connection.respond_error(state.conn, id, -32_000, "write denied: read-only review context")
    {:noreply, state}
  end

  defp handle_agent_request("fs/write_text_file", id, params, state) do
    path = params["path"]

    with :ok <- check_sandbox(path, state.context.path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, params["content"] || "") do
      Connection.respond(state.conn, id, nil)
    else
      {:error, reason} ->
        Connection.respond_error(state.conn, id, -32_000, "write failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp handle_agent_request("session/request_permission", id, params, state) do
    tool_call = params["toolCall"] || %{}
    options = params["options"] || []

    if escalation?(tool_call, state.context.path) do
      detail = tool_call["title"] || tool_call["kind"] || "permission request"
      emit(state, {:permission_request, %{id: id, detail: detail}})

      # Keyed by the stringified id so answers surviving a JSON or DB
      # round-trip (always strings) still match integer JSON-RPC ids.
      pending = Map.put(state.pending_permissions, to_string(id), {id, options})
      {:noreply, %{state | pending_permissions: pending}}
    else
      Connection.respond(state.conn, id, permission_outcome(options, true))
      {:noreply, state}
    end
  end

  # We never advertise url mode, so a url elicitation can only be a
  # harness bug; decline rather than strand the agent on a request we
  # have no surface for.
  defp handle_agent_request("elicitation/create", id, %{"mode" => "url"}, state) do
    Connection.respond(state.conn, id, %{action: "decline"})
    {:noreply, state}
  end

  defp handle_agent_request("elicitation/create", id, params, state) do
    case Elicitation.form_fields(params["requestedSchema"]) do
      [] ->
        Connection.respond(state.conn, id, %{action: "decline"})
        {:noreply, state}

      fields ->
        emit(
          state,
          {:question,
           %{
             id: id,
             detail: params["message"] || "The agent needs an answer",
             fields: fields,
             tool_call_id: params["toolCallId"]
           }}
        )

        # Left unanswered on purpose — the open request is what holds the
        # agent's turn. Keyed by the stringified id for the same reason
        # as `pending_permissions`: answers arrive back as strings.
        pending = Map.put(state.pending_questions, to_string(id), {id, fields})
        {:noreply, %{state | pending_questions: pending}}
    end
  end

  defp handle_agent_request("terminal/create", id, params, state) do
    terminal_id = "term-#{System.unique_integer([:positive])}"
    command = params["command"]
    args = params["args"] || []
    cwd = params["cwd"] || state.context.path
    env = state.context.env ++ decode_env(params["env"] || [])

    task =
      Task.Supervisor.async_nolink(CodeLead.TaskSupervisor, fn ->
        run_terminal_command(command, args, cwd, env)
      end)

    Connection.respond(state.conn, id, %{terminalId: terminal_id})

    terminals =
      Map.put(state.terminals, terminal_id, %{
        task_ref: task.ref,
        task_pid: task.pid,
        result: nil,
        exit_waiters: []
      })

    {:noreply, %{state | terminals: terminals}}
  end

  defp handle_agent_request("terminal/output", id, params, state) do
    case state.terminals[params["terminalId"]] do
      %{result: {output, exit_status}} ->
        Connection.respond(state.conn, id, %{
          output: output,
          truncated: false,
          exitStatus: %{exitCode: exit_status, signal: nil}
        })

      %{result: nil} ->
        Connection.respond(state.conn, id, %{output: "", truncated: false, exitStatus: nil})

      nil ->
        Connection.respond_error(state.conn, id, -32_000, "unknown terminal")
    end

    {:noreply, state}
  end

  defp handle_agent_request("terminal/wait_for_exit", id, params, state) do
    terminal_id = params["terminalId"]

    case state.terminals[terminal_id] do
      %{result: {_output, exit_status}} ->
        Connection.respond(state.conn, id, %{exitCode: exit_status, signal: nil})
        {:noreply, state}

      %{result: nil} = terminal ->
        terminals =
          Map.put(state.terminals, terminal_id, %{
            terminal
            | exit_waiters: [id | terminal.exit_waiters]
          })

        {:noreply, %{state | terminals: terminals}}

      nil ->
        Connection.respond_error(state.conn, id, -32_000, "unknown terminal")
        {:noreply, state}
    end
  end

  defp handle_agent_request("terminal/kill", id, params, state) do
    case state.terminals[params["terminalId"]] do
      %{result: nil, task_pid: pid} ->
        Task.Supervisor.terminate_child(CodeLead.TaskSupervisor, pid)
        Connection.respond(state.conn, id, nil)

      %{} ->
        Connection.respond(state.conn, id, nil)

      nil ->
        Connection.respond_error(state.conn, id, -32_000, "unknown terminal")
    end

    {:noreply, state}
  end

  defp handle_agent_request("terminal/release", id, params, state) do
    Connection.respond(state.conn, id, nil)
    {:noreply, %{state | terminals: Map.delete(state.terminals, params["terminalId"])}}
  end

  defp handle_agent_request(method, id, _params, state) do
    Connection.respond_error(state.conn, id, -32_601, "method not supported: #{method}")
    {:noreply, state}
  end

  ## Terminal plumbing

  defp decode_env(env_vars) do
    Enum.map(env_vars, fn %{"name" => name, "value" => value} -> {name, value} end)
  end

  defp run_terminal_command(command, args, cwd, env) do
    case System.find_executable(command) do
      nil ->
        {"executable not found: #{command}", 127}

      resolved ->
        {output, exit_status} =
          System.cmd(resolved, args,
            cd: cwd,
            env: EnvScrub.cmd_env(env),
            stderr_to_stdout: true
          )

        {output, exit_status}
    end
  end

  defp complete_terminal(state, task_ref, result) do
    case Enum.find(state.terminals, fn {_tid, t} -> t.task_ref == task_ref end) do
      nil ->
        state

      {terminal_id, terminal} ->
        {_output, exit_status} = result

        Enum.each(terminal.exit_waiters, fn rpc_id ->
          Connection.respond(state.conn, rpc_id, %{exitCode: exit_status, signal: nil})
        end)

        terminals =
          Map.put(state.terminals, terminal_id, %{terminal | result: result, exit_waiters: []})

        %{state | terminals: terminals}
    end
  end

  ## Helpers

  defp open_connection(agent, context, command) do
    provider = Agents.get_provider!(agent.provider_id)
    env = context.env ++ Agents.provider_env(provider)
    context = %{context | env: env}

    Connection.start_link(
      owner: self(),
      port_opener: fn -> context.executor.spawn(context, command) end
    )
  end

  defp harness_command(agent) do
    harnesses = Application.get_env(:code_lead, :harnesses, %{})

    case harnesses[agent.harness] do
      nil -> {:error, {:unknown_harness, agent.harness}}
      command -> {:ok, command}
    end
  end

  defp initialize_params(elicitation?) do
    %{
      protocolVersion: 1,
      clientCapabilities:
        %{fs: %{readTextFile: true, writeTextFile: true}, terminal: true}
        |> put_elicitation(elicitation?)
    }
  end

  # An empty map is how the protocol spells "supported"; omitting the key
  # is how it spells "not supported". Only form mode — we have no surface
  # for sending a human off to a url.
  defp put_elicitation(capabilities, true), do: Map.put(capabilities, :elicitation, %{form: %{}})
  defp put_elicitation(capabilities, false), do: capabilities

  defp permission_outcome(options, granted?) do
    wanted =
      if granted?, do: ["allow_once", "allow_always"], else: ["reject_once", "reject_always"]

    option =
      Enum.find(options, fn option -> option["kind"] in wanted end) || List.first(options)

    case option do
      nil -> %{outcome: %{outcome: "cancelled"}}
      %{"optionId" => option_id} -> %{outcome: %{outcome: "selected", optionId: option_id}}
    end
  end

  defp question_content(fields, {:accept, values}), do: Elicitation.content(fields, values)
  defp question_content(_fields, _answer), do: %{}

  # An accept with empty content is still an accept — the agent reads it
  # as "the human answered nothing", which is what a cleared form means.
  # Recording it as a decline would put the transcript at odds with the
  # wire.
  defp question_outcome(content, {:accept, _values}), do: %{action: "accept", content: content}
  defp question_outcome(_content, :decline), do: %{action: "decline"}
  defp question_outcome(_content, :cancel), do: %{action: "cancel"}

  defp escalation?(tool_call, sandbox_path) do
    (tool_call["locations"] || [])
    |> Enum.map(& &1["path"])
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn path -> check_sandbox(path, sandbox_path) != :ok end)
  end

  defp check_sandbox(nil, _sandbox_path), do: {:error, :outside_sandbox}

  defp check_sandbox(path, sandbox_path) do
    expanded = Path.expand(path)

    if String.starts_with?(expanded, Path.expand(sandbox_path) <> "/") do
      :ok
    else
      {:error, :outside_sandbox}
    end
  end

  # ACP spells `PromptResponse.usage` in camelCase (`inputTokens`,
  # `cachedReadTokens`, …). The snake_case spellings are kept as
  # fallbacks so Anthropic/OpenAI-shaped payloads from other harnesses
  # still land.
  defp extract_usage(result) do
    usage = result["usage"] || get_in(result, ["_meta", "usage"])

    case usage do
      %{} = usage ->
        prompt_tokens = pick(usage, ["inputTokens", "input_tokens", "prompt_tokens"])
        completion_tokens = pick(usage, ["outputTokens", "output_tokens", "completion_tokens"])
        cached_read = pick(usage, ["cachedReadTokens", "cache_read_input_tokens"])
        cached_write = pick(usage, ["cachedWriteTokens", "cache_creation_input_tokens"])
        reasoning = pick(usage, ["thoughtTokens", "reasoning_tokens"])

        total =
          pick(usage, ["totalTokens", "total_tokens"], nil) ||
            prompt_tokens + completion_tokens + cached_read + cached_write

        %{
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          cached_read_tokens: cached_read,
          cached_write_tokens: cached_write,
          reasoning_tokens: reasoning,
          total_tokens: total,
          cost_cents: usage["cost_cents"]
        }

      nil ->
        nil
    end
  end

  # `default` is nil where the caller must tell "absent" from "zero" —
  # a reported total of 0 is not the same as no total at all.
  defp pick(usage, keys, default \\ 0) do
    Enum.find_value(keys, default, fn key ->
      case usage[key] do
        n when is_integer(n) -> n
        _other -> nil
      end
    end)
  end

  defp cost_cents(%{"amount" => amount}) when is_number(amount), do: round(amount * 100)
  defp cost_cents(_cost), do: nil

  # Runs that end without a `PromptResponse` (cancel, crash, protocol
  # error) still burned money the harness already told us about — report
  # it rather than recording the run as free.
  defp settled_usage(%{usage: nil, cost_cents: nil}), do: nil

  defp settled_usage(%{usage: nil, cost_cents: cents, context_used: used}) do
    %{
      prompt_tokens: 0,
      completion_tokens: 0,
      cached_read_tokens: 0,
      cached_write_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: used || 0,
      cost_cents: cents
    }
  end

  defp settled_usage(%{usage: usage, cost_cents: cents}), do: with_cost_cents(usage, cents)

  defp with_cost_cents(%{cost_cents: cents} = usage, _fallback) when is_integer(cents), do: usage
  defp with_cost_cents(usage, fallback), do: %{usage | cost_cents: fallback}

  defp emit(state, event) do
    send(state.caller, {:agent_event, self(), event})
  end

  defp finish(state, result) do
    result = Map.put_new(result, :session_id, state.session_id)
    emit(state, {:result, result})

    # Settle anything the agent is still blocked on before the pipe goes
    # away. The harness unwinds these on its own abort signal, so this is
    # about leaving no wedged subprocess if that path ever regresses.
    Enum.each(state.pending_questions, fn {_ref, {id, _fields}} ->
      Connection.respond(state.conn, id, %{action: "cancel"})
    end)

    Connection.close(state.conn)
    {:stop, :normal, state}
  end
end
