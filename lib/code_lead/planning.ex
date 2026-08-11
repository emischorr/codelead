defmodule CodeLead.Planning do
  @moduledoc """
  The AI planning assistant: a chat per task that helps refine the
  spec, with read-only context from the linked repo. Its output
  crystallizes when the human writes it into the task
  (`Tasks.update_task(task, %{spec: ...})`) — the assistant never
  changes the task itself.
  """

  import Ecto.Query

  alias CodeLead.AgentDriver.LlmApi
  alias CodeLead.Agents
  alias CodeLead.Costs
  alias CodeLead.Git
  alias CodeLead.Planning.PlanningMessage
  alias CodeLead.Projects
  alias CodeLead.Repo
  alias CodeLead.Tasks.Task

  @file_tree_limit 200

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

    insert_message(task.id, :user, content)
    history = Enum.map(list_messages(task.id), &%{role: &1.role, content: &1.content})
    messages = [%{role: :user, content: context_preamble(task)} | history]

    case LlmApi.complete(provider.kind, provider.config, agent, messages) do
      {:ok, reply, usage} ->
        record_usage(task, agent, usage, :ok, started_at, monotonic_start)
        {:ok, insert_message(task.id, :assistant, reply)}

      {:error, reason} ->
        record_usage(task, agent, nil, :error, started_at, monotonic_start)
        {:error, reason}
    end
  end

  @doc """
  Interactive chat loop for the IEx console. Type `exit` to leave.
  """
  @spec chat(pos_integer(), pos_integer()) :: :ok
  def chat(task_id, agent_id) do
    task = CodeLead.Tasks.get_task!(task_id)

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

  defp insert_message(task_id, role, content) do
    Repo.insert!(%PlanningMessage{task_id: task_id, role: role, content: content})
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

    with path when is_binary(path) <- repository.base_clone_path,
         true <- File.dir?(path),
         {:ok, output} <- Git.git(path, ["ls-files"]) do
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
