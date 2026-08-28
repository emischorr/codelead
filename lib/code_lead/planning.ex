defmodule CodeLead.Planning do
  @moduledoc """
  The planning workbench's AI surface: a conversation per task that
  helps refine the spec. Its output crystallizes when the human writes
  it into the task (`Tasks.update_task(task, %{spec: ...})`) — nothing
  here changes the task itself.

  One entry point, `start_refinement/2`, whose depth is selected by the
  **driver** of the `:plan`-role agent the human picks:

  - `:llm_api` → **task-level**: a single completion over the task
    fields plus a repository file listing.
  - `:acp` → **repo-level**: a read-only agent reads current
    default-branch source and reports requirement gaps, contradictions,
    and unstated assumptions.

  Both produce the same two-part report (narrative + findings JSON
  tail) and land as a `:survey` turn parsed into findings. The chat
  loop (`send_message/3`, `chat/2`) remains for the IEx console only —
  the web UI has no chat interface.

  The survey is the reviewer primitive moved upstream — same
  `CodeLead.AdvisoryRun`, same read-only posture, same advisory status.
  It differs only in *when* it runs (in Planning, pulled by a human,
  never on a transition) and *where its output lands* (a
  `planning_messages` turn, not the `reviews` table).

  Both are cost-tracked; neither is budget-gated.
  """

  import Ecto.Query

  require Logger

  alias CodeLead.AdvisoryRun
  alias CodeLead.AgentDriver.LlmApi
  alias CodeLead.Agents
  alias CodeLead.Agents.Agent
  alias CodeLead.Costs
  alias CodeLead.Executor.Context
  alias CodeLead.Findings
  alias CodeLead.Findings.Report
  alias CodeLead.Git
  alias CodeLead.Planning.PlanningMessage
  alias CodeLead.Projects
  alias CodeLead.Repo
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @file_tree_limit 200
  @survey_timeout :timer.minutes(15)

  @spec list_messages(pos_integer()) :: [PlanningMessage.t()]
  def list_messages(task_id) do
    Repo.all(from m in PlanningMessage, where: m.task_id == ^task_id, order_by: [asc: m.id])
  end

  @doc """
  One chat turn: persists the user message, asks the agent (with task
  fields and a read-only repo file tree as context), persists and
  returns the assistant reply. Usage is cost-tracked.
  """
  @spec send_message(Task.t(), pos_integer(), String.t()) ::
          {:ok, PlanningMessage.t()} | {:error, term()}
  def send_message(%Task{} = task, agent_id, content) do
    agent = Agents.get_agent!(agent_id)
    provider = Agents.get_provider!(agent.provider_id)
    started_at = DateTime.utc_now(:second)
    monotonic_start = System.monotonic_time(:millisecond)

    insert_message(task.id, :user, content, [])
    history = Enum.map(chat_history(task.id), &%{role: &1.role, content: &1.content})
    messages = [%{role: :user, content: context_preamble(task)} | history]

    case LlmApi.complete(provider.kind, provider.config, agent, messages) do
      {:ok, reply, usage} ->
        record_usage(task, agent, usage, :ok, started_at, monotonic_start)
        {:ok, insert_message(task.id, :assistant, reply, agent_id: agent.id)}

      {:error, reason} ->
        record_usage(task, agent, nil, :error, started_at, monotonic_start)
        {:error, reason}
    end
  end

  @doc """
  Starts a one-shot refinement with a `:plan` agent: an `:acp` agent
  runs the repo-aware survey, an `:llm_api` agent a single completion
  over the task fields. Both report gaps in the task's spec.

  Runs asynchronously and appends its findings as a `:survey` turn;
  completion is announced as `{:survey_completed, _}` on the task
  topic. Nothing about the card moves and no attention is raised — the
  human pulled this.
  """
  @spec start_refinement(Task.t(), pos_integer()) :: {:ok, :started} | {:error, term()}
  def start_refinement(%Task{} = task, agent_id) do
    agent = Agents.get_agent!(agent_id)

    with :ok <- check_planner(agent, task),
         :ok <- check_repository(agent, task) do
      Elixir.Task.Supervisor.start_child(CodeLead.TaskSupervisor, fn ->
        run_refinement(task, agent)
      end)

      {:ok, :started}
    end
  end

  @doc """
  Interactive chat loop for the IEx console. Type `exit` to leave.
  """
  @spec chat(pos_integer(), pos_integer()) :: :ok
  def chat(task_id, agent_id) do
    task = Tasks.get_task!(task_id)

    case String.trim(IO.gets("you> ")) do
      "exit" ->
        :ok

      "" ->
        chat(task_id, agent_id)

      input ->
        case send_message(task, agent_id, input) do
          {:ok, reply} -> IO.puts("\nassistant> #{reply.content}\n")
          {:error, reason} -> IO.puts("\n[error] #{inspect(reason)}\n")
        end

        chat(task_id, agent_id)
    end
  end

  @doc false
  @spec survey_prompt(Task.t()) :: String.t()
  def survey_prompt(%Task{} = task) do
    """
    You are surveying an existing codebase on behalf of a product owner \
    who is still writing this task's spec. You are read-only: do not \
    write or modify any code, and do not create branches or commits.

    Read the repository you have been given — it is checked out at the \
    current default branch — and compare it against the task below.

    #{report_contract()}\
    #{task_section(task)}\
    """
  end

  @doc false
  @spec refinement_prompt(Task.t()) :: String.t()
  def refinement_prompt(%Task{} = task) do
    """
    You are reviewing a task on behalf of a product owner who is still \
    writing its spec. You cannot read the repository — work from the \
    task fields below and, when present, the repository file listing.

    #{report_contract()}\
    #{task_section(task)}#{repo_context(task)}\
    """
  end

  ## Refinement execution (inside CodeLead.TaskSupervisor)

  defp check_planner(%Agent{} = agent, %Task{} = task) do
    if Agents.eligible?(agent, task.work_type, task.project_id, :plan),
      do: :ok,
      else: {:error, :planner_ineligible}
  end

  # Only the repo-level survey needs source to read; a task-level
  # refinement works from the task fields alone.
  defp check_repository(%Agent{driver: :acp}, %Task{repository_id: nil}),
    do: {:error, :missing_repository}

  defp check_repository(%Agent{}, %Task{}), do: :ok

  defp run_refinement(%Task{} = task, %Agent{} = agent) do
    started_at = DateTime.utc_now(:second)
    monotonic_start = System.monotonic_time(:millisecond)

    # The stored summary stays technical — it is the run counter's match
    # key (`Findings.survey_run_count/1`) and is display-mapped by
    # `CodeLeadWeb.Format.step_summary/1`.
    {summary_key, result} =
      case agent.driver do
        :acp ->
          {"repo survey",
           survey_result(task, agent, Projects.get_repository!(task.repository_id))}

        :llm_api ->
          {"task refinement", refinement_result(task, agent)}
      end

    step =
      Tasks.record_step(
        task.id,
        :plan,
        :agent,
        agent.name,
        "#{summary_key}: #{result.status}",
        Integer.to_string(agent.id)
      )

    Costs.record_run(%{
      task_id: task.id,
      task_step_id: step.id,
      agent_id: agent.id,
      provider_id: agent.provider_id,
      usage: Costs.with_cost(result[:usage], agent.model_variant),
      status: result.status,
      started_at: started_at,
      finished_at: DateTime.utc_now(:second),
      duration_ms: System.monotonic_time(:millisecond) - monotonic_start
    })

    insert_message(task.id, :assistant, findings(result), kind: :survey, agent_id: agent.id)

    delta = apply_findings(task, step, agent, result)

    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      Tasks.task_topic(task.id),
      {:task_event, task.id,
       {:survey_completed, %{agent: agent.name, status: result.status, delta: delta}}}
    )
  end

  # A report whose findings block does not parse writes no rows and
  # degrades to the raw turn (delta nil) — never a survey failure.
  defp apply_findings(task, step, agent, %{status: :ok, content: content}) do
    case Findings.apply_report(task, :planning, step, agent, content) do
      {:ok, delta} -> delta
      :error -> nil
    end
  end

  defp apply_findings(_task, _step, _agent, _result), do: nil

  # The task-level depth: one completion, no execution context at all.
  defp refinement_result(%Task{} = task, %Agent{} = agent) do
    provider = Agents.get_provider!(agent.provider_id)
    messages = [%{role: :user, content: refinement_prompt(task)}]

    case LlmApi.complete(provider.kind, provider.config, agent, messages) do
      {:ok, reply, usage} -> %{status: :ok, content: reply, usage: usage}
      {:error, reason} -> failed("refinement failed: #{inspect(reason)}")
    end
  end

  defp survey_result(%Task{} = task, %Agent{} = agent, repository) do
    case provision_survey(task, repository) do
      {:ok, base_clone_path, worktree_path} ->
        # The struct default keeps the survey on the local executor even
        # for a `:container` task: its disposable detached worktree has
        # no container, and never should.
        context = %Context{
          type: :worktree,
          path: worktree_path,
          task_id: task.id,
          base_clone_path: base_clone_path,
          base_branch: repository.default_branch,
          env: Projects.env_vars(task.project_id),
          read_only: true
        }

        try do
          # `%{task | acp_session_id: nil}` is the invariant, not an
          # optimization: the ACP driver resumes `task.acp_session_id`
          # when it is set, and a survey must never occupy or mutate
          # the task's execution session.
          run_opts = [timeout: @survey_timeout]
          survey = %{task | acp_session_id: nil}

          case AdvisoryRun.run(survey, agent, context, survey_prompt(task), run_opts) do
            {:ok, result} -> result
            {:error, reason} -> failed("survey failed: #{inspect(reason)}")
          end
        after
          case Git.remove_worktree(base_clone_path, worktree_path) do
            :ok -> :ok
            {:error, {:leftover, path}} -> Logger.warning("survey worktree left at #{path}")
          end
        end

      {:error, reason} ->
        failed("survey context unavailable: #{inspect(reason)}")
    end
  end

  # A disposable, detached checkout of current default-branch source:
  # no feature branch, nothing committed, removed when the run ends.
  defp provision_survey(%Task{} = task, repository) do
    base_clone_path = Projects.base_clone_path(repository)
    worktree_path = Workspace.survey_worktree_path(task.id)
    token = forge_token(task.project_id, Git.forge(repository.git_url))

    with {:ok, _} <- Git.ensure_clone(repository.git_url, base_clone_path, token: token),
         :ok <- persist_base_clone_path(repository, base_clone_path),
         # A leftover from an earlier survey — or from an earlier
         # database generation handed the same task id — is never
         # adopted, only removed.
         :ok <- Git.remove_worktree(base_clone_path, worktree_path),
         {:ok, _} <-
           Git.create_detached_worktree(
             base_clone_path,
             worktree_path,
             repository.default_branch
           ) do
      {:ok, base_clone_path, worktree_path}
    end
  end

  defp forge_token(_project_id, :other), do: nil
  defp forge_token(project_id, {kind, _owner, _repo}), do: Projects.forge_token(project_id, kind)

  defp persist_base_clone_path(%{base_clone_path: path}, path), do: :ok

  defp persist_base_clone_path(repository, path) do
    with {:ok, _} <- Projects.update_repository(repository, %{base_clone_path: path}), do: :ok
  end

  defp failed(detail), do: %{status: :error, content: detail, usage: nil}

  defp findings(%{status: :ok} = result), do: result[:content] || "The run returned nothing."
  defp findings(%{status: status} = result), do: "Refinement #{status}: #{result[:content]}"

  # The report contract shared by both refinement depths: the planning
  # lenses around the phase-agnostic output shape
  # (`Findings.Report.output_contract/1`).
  defp report_contract do
    """
    Look for three things: requirements gaps (what someone implementing \
    this would have to decide), contradictions between the task and the \
    existing code, docs or conventions, and unstated assumptions or \
    open questions. Do not label items by these categories — they are \
    lenses, not output sections.

    Assume the reader already has a general knowledge of what this \
    project is and how it is built. Do not report broad or obvious \
    observations — the language or framework in use, the overall \
    structure, the fact that code exists. Report only things someone \
    scoping this specific task would act on.

    #{Report.output_contract(narrative: "what exists today that is relevant to this task, with file paths. Be specific and cite paths. No process narration, no restating the task.", body: "why it matters and what has to be decided", severity: "high = must be decided before this task can run; medium = should be decided, an implementer could guess wrong; low = worth clarifying, low risk either way.", prior: ~s(If a prior finding is now covered by the spec or the decisions, mark it "resolved". If the task changed so it no longer applies, mark it "not_applicable".))}

    This report is advisory: the human rewrites the spec, not you.\
    """
  end

  defp task_section(%Task{} = task) do
    """
    ## Task
    Title: #{task.title}
    Work type: #{task.work_type} | Target: #{task.target} | Priority: #{task.priority}
    Description: #{task.description || "(none)"}
    Current spec: #{task.spec || "(none)"}
    #{prior_findings_section(task)}#{decisions_section(task)}\
    """
  end

  # All prior findings — every state — so the agent classifies instead
  # of re-reporting, and never re-adds a dismissed item as new.
  defp prior_findings_section(%Task{} = task) do
    task.id |> Findings.prior_for_prompt(:planning) |> Findings.prior_section()
  end

  defp decisions_section(%Task{} = task) do
    case Findings.decisions_block(task.id) do
      "" -> ""
      block -> "\n" <> block <> "\n"
    end
  end

  ## Messages

  # Survey reports are standalone artifacts, not conversation: replaying
  # a multi-KB report as history would resend it on every later turn.
  defp chat_history(task_id) do
    Repo.all(
      from m in PlanningMessage,
        where: m.task_id == ^task_id and m.kind == :chat,
        order_by: [asc: m.id]
    )
  end

  defp insert_message(task_id, role, content, opts) do
    Repo.insert!(%PlanningMessage{
      task_id: task_id,
      agent_id: opts[:agent_id],
      role: role,
      kind: Keyword.get(opts, :kind, :chat),
      content: content
    })
  end

  defp context_preamble(task) do
    """
    You are the planning assistant for a task on a Kanban board. Help \
    the user refine the task into a clear spec with acceptance \
    criteria, and surface open questions. You have read-only context; \
    you cannot change files or the task yourself.

    ## Task
    Title: #{task.title}
    Work type: #{task.work_type} | Target: #{task.target} | Priority: #{task.priority}
    Description: #{task.description || "(none)"}
    Current spec: #{task.spec || "(none)"}
    #{decisions_section(task)}#{repo_context(task)}
    """
  end

  defp repo_context(%Task{repository_id: nil}), do: ""

  defp repo_context(%Task{repository_id: repository_id}) do
    repository = Projects.get_repository!(repository_id)

    path = Projects.base_clone_path(repository)

    # `ls-tree` against the fetched ref, not `ls-files` against the base
    # clone's index: `Git.ensure_clone/3` only fetches, so the clone's
    # own checkout is frozen at whatever it was first cloned at.
    with true <- File.dir?(path),
         {:ok, output} <-
           Git.git(path, ["ls-tree", "-r", "--name-only", "origin/#{repository.default_branch}"]) do
      files = output |> String.split("\n", trim: true) |> Enum.take(@file_tree_limit)

      """

      ## Repository file tree (#{repository.name}, read-only, truncated to #{@file_tree_limit})
      #{Enum.join(files, "\n")}
      """
    else
      _no_clone -> ""
    end
  end

  defp record_usage(task, agent, usage, status, started_at, monotonic_start) do
    Costs.record_run(%{
      task_id: task.id,
      agent_id: agent.id,
      provider_id: agent.provider_id,
      usage: Costs.with_cost(usage, agent.model_variant),
      status: status,
      started_at: started_at,
      finished_at: DateTime.utc_now(:second),
      duration_ms: System.monotonic_time(:millisecond) - monotonic_start
    })
  end
end
