defmodule CodeLead.Planning do
  @moduledoc """
  The planning workbench's AI surface: a conversation per task that
  helps refine the spec. Its output crystallizes when the human writes
  it into the task (`Tasks.update_task(task, %{spec: ...})`) — nothing
  here changes the task itself.

  Two capabilities, selected by the **driver** of the `:plan`-role
  agent the human picks:

  - `:llm_api` → `send_message/3`, a single completion that refines the
    description and spec from text plus a repository file listing.
  - `:acp` → `start_survey/2`, a **repo-aware survey**: a read-only
    agent reads current default-branch source and reports requirement
    gaps, contradictions, and unstated assumptions.

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
  Starts a repo-aware survey with an `:acp` plan agent: reads current
  default-branch source read-only and reports gaps in the task's spec.

  Runs asynchronously and appends its findings as a `:survey` turn;
  completion is announced as `{:survey_completed, _}` on the task
  topic. Nothing about the card moves and no attention is raised — the
  human pulled this.
  """
  @spec start_survey(Task.t(), pos_integer()) :: {:ok, :started} | {:error, term()}
  def start_survey(%Task{} = task, agent_id) do
    agent = Agents.get_agent!(agent_id)

    with :ok <- check_planner(agent, task),
         :ok <- check_repository(task) do
      Elixir.Task.Supervisor.start_child(CodeLead.TaskSupervisor, fn ->
        run_survey(task, agent)
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

  ## Survey execution (inside CodeLead.TaskSupervisor)

  defp check_planner(%Agent{driver: :acp} = agent, %Task{} = task) do
    if Agents.eligible?(agent, task.work_type, task.project_id, :plan),
      do: :ok,
      else: {:error, :planner_ineligible}
  end

  defp check_planner(%Agent{}, %Task{}), do: {:error, :not_repo_aware}

  defp check_repository(%Task{repository_id: nil}), do: {:error, :missing_repository}
  defp check_repository(%Task{}), do: :ok

  defp run_survey(%Task{} = task, %Agent{} = agent) do
    repository = Projects.get_repository!(task.repository_id)
    started_at = DateTime.utc_now(:second)
    monotonic_start = System.monotonic_time(:millisecond)

    result = survey_result(task, agent, repository)

    step =
      Tasks.record_step(
        task.id,
        :plan,
        :agent,
        agent.name,
        "repo survey: #{result.status}",
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

    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      Tasks.task_topic(task.id),
      {:task_event, task.id, {:survey_completed, %{agent: agent.name, status: result.status}}}
    )
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

  defp findings(%{status: :ok} = result), do: result[:content] || "The survey returned nothing."
  defp findings(%{status: status} = result), do: "Survey #{status}: #{result[:content]}"

  defp survey_prompt(%Task{} = task) do
    """
    You are surveying an existing codebase on behalf of a product owner \
    who is still writing this task's spec. You are read-only: do not \
    write or modify any code, and do not create branches or commits.

    Read the repository you have been given — it is checked out at the \
    current default branch — and compare it against the task below. \
    Report:

    1. **Requirements gaps** — what the spec does not say that someone \
       implementing this would have to decide.
    2. **Contradictions** — where the description or spec disagrees \
       with the existing code, docs, or conventions. Cite files.
    3. **Unstated assumptions and open questions** — what the spec \
       takes for granted, and what you would need answered.

    Be specific and cite paths. This survey is advisory: the human \
    rewrites the spec, not you.

    ## Task
    Title: #{task.title}
    Work type: #{task.work_type} | Target: #{task.target} | Priority: #{task.priority}
    Description: #{task.description || "(none)"}
    Current spec: #{task.spec || "(none)"}
    """
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
    #{repo_context(task)}
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
