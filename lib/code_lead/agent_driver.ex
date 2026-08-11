defmodule CodeLead.AgentDriver do
  @moduledoc """
  Behaviour for running an agent and consuming its normalized event
  stream. Two MVP implementations: `Acp` (a coding harness driven over
  the Agent Client Protocol) and `LlmApi` (a single completion call).

  ## Event contract

  The process that calls `start_run/4` receives events as messages:

      {:agent_event, handle, event}

  where `event` is one of

    * `{:message_chunk, text}` — streamed assistant output
    * `{:tool_call, %{id: id, title: title, kind: kind, status: status,
      locations: locations, raw_input: raw_input}}` — the agent used a
      tool. Emitted once per status change for the same `id`, with only
      `id` and `status` guaranteed non-nil after the first; correlate
      and merge rather than treating each as a new call. `raw_input` is
      unbounded and untrusted — truncate and redact before storing it
    * `{:permission_request, %{id: id, detail: detail}}` — an escalation
      that needs a human decision (in-sandbox requests are auto-granted
      by the driver and never surface here)
    * `{:question, text}` — the agent asks the human something
    * `{:session_started, session_id}` — an ACP session exists; the
      runner persists it for later resume
    * `{:usage, snapshot}` — advisory mid-run usage; may arrive any
      number of times or not at all, and each one supersedes the last.
      Drives the live cost/token readout while a run executes
    * `{:result, result}` — terminal event, exactly one per run

  and `result` is

      %{
        status: :ok | :error | :cancelled,
        content: String.t() | nil,   # final message or error detail
        usage: usage() | nil,
        session_id: String.t() | nil # ACP session to resume, if any
      }

  Usage reports tokens, split into fresh input/output plus the cache and
  reasoning counters the backend breaks out. `cost_cents` is `nil` unless
  the backend reports money directly — ACP harnesses generally do, and
  their figure is authoritative because it prices cache reads/writes,
  which `CodeLead.Costs.with_cost/2` cannot.

  Task state is derived from these protocol events, never from agent
  self-report.
  """

  alias CodeLead.Agents.Agent
  alias CodeLead.Executor.Context
  alias CodeLead.Tasks.Task

  @type handle :: term()
  @type prompt :: String.t() | [%{role: atom() | String.t(), content: String.t()}]

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          cached_read_tokens: non_neg_integer(),
          cached_write_tokens: non_neg_integer(),
          reasoning_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost_cents: non_neg_integer() | nil
        }

  @typedoc """
  Advisory mid-run usage. `cost_cents` is cumulative money for the run so
  far; `context_used`/`context_size` describe context-window occupancy,
  which is not the same as tokens billed — the exact billed split only
  arrives with the terminal result.
  """
  @type usage_snapshot :: %{
          cost_cents: non_neg_integer() | nil,
          context_used: non_neg_integer() | nil,
          context_size: non_neg_integer() | nil
        }

  @type result :: %{
          status: :ok | :error | :cancelled,
          content: String.t() | nil,
          usage: usage() | nil,
          session_id: String.t() | nil
        }

  @type event ::
          {:message_chunk, String.t()}
          | {:tool_call, map()}
          | {:permission_request, map()}
          | {:question, String.t()}
          | {:session_started, String.t()}
          | {:usage, usage_snapshot()}
          | {:result, result()}

  @doc """
  Checks that the agent could actually be launched — the harness binary
  exists, the configuration resolves. Run before the execution context is
  provisioned so an unusable agent fails fast rather than after a clone.
  """
  @callback preflight(agent :: Agent.t()) :: :ok | {:error, term()}

  @doc """
  Starts a run; events flow to the calling process. `context` is `nil`
  for runs that need no filesystem (e.g. an llm_api review over an
  in-prompt diff).
  """
  @callback start_run(
              task :: Task.t(),
              agent :: Agent.t(),
              context :: Context.t() | nil,
              prompt :: prompt()
            ) :: {:ok, handle()} | {:error, term()}

  @doc """
  Sends a follow-up message into a running session (answers to agent
  questions, permission decisions).
  """
  @callback send_message(handle(), String.t()) :: :ok | {:error, term()}

  @doc """
  Aborts the run. The driver emits a final `{:result, %{status:
  :cancelled}}` if the run was still alive.
  """
  @callback cancel(handle()) :: :ok

  @doc """
  Resolves the driver module for an agent.
  """
  @spec impl(Agent.t()) :: module()
  def impl(%Agent{driver: :acp}), do: CodeLead.AgentDriver.Acp
  def impl(%Agent{driver: :llm_api}), do: CodeLead.AgentDriver.LlmApi
end
