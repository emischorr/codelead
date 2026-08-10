defmodule CodeLead.Executor.LocalSubprocess do
  @moduledoc """
  MVP executor: worktree / task-folder on the workspace volume, agent
  CLIs run as local subprocesses with the project env injected.
  """

  @behaviour CodeLead.Executor

  alias CodeLead.Executor.Context
  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @impl CodeLead.Executor
  def provision(%Task{target: :repo, repository_id: repository_id} = task)
      when not is_nil(repository_id) do
    repository = Projects.get_repository!(repository_id)

    base_path =
      repository.base_clone_path || Workspace.base_clone_path(repository.name, repository.id)

    with {:ok, _} <- Git.ensure_clone(repository.git_url, base_path),
         :ok <- persist_base_clone_path(repository, base_path),
         {:ok, task, worktree_path, branch} <- ensure_worktree(task, repository, base_path) do
      {:ok,
       %Context{
         type: :worktree,
         path: worktree_path,
         task_id: task.id,
         base_clone_path: base_path,
         branch_name: branch,
         base_branch: repository.default_branch,
         env: Projects.env_vars(task.project_id)
       }}
    end
  end

  def provision(%Task{target: :folder} = task) do
    path = Workspace.task_folder(task.id)
    File.mkdir_p!(path)

    {:ok,
     %Context{
       type: :folder,
       path: path,
       task_id: task.id,
       env: Projects.env_vars(task.project_id)
     }}
  end

  @impl CodeLead.Executor
  def spawn(%Context{path: path, env: env}, [executable | args], port_opts \\ []) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      resolved ->
        port =
          Port.open(
            {:spawn_executable, resolved},
            [
              :binary,
              :exit_status,
              :hide,
              :stderr_to_stdout,
              args: args,
              cd: path,
              env: charlist_env(env)
            ] ++ port_opts
          )

        {:ok, port}
    end
  end

  @impl CodeLead.Executor
  def teardown(context, opts) do
    if Keyword.get(opts, :keep, true), do: :ok, else: discard(context)
  end

  defp discard(%Context{type: :worktree} = context) do
    Git.remove_worktree(context.base_clone_path, context.path)
    Git.delete_branch(context.base_clone_path, context.branch_name)
    :ok
  end

  defp discard(%Context{type: :folder, path: path}) do
    _ = File.rm_rf(path)
    :ok
  end

  defp ensure_worktree(task, repository, base_path) do
    branch = task.branch_name || "codelead/task-#{task.id}-#{Workspace.slug(task.title)}"
    worktree_path = task.worktree_path || Workspace.worktree_path(task.id)

    if File.dir?(worktree_path) do
      {:ok, task, worktree_path, branch}
    else
      with {:ok, _} <-
             Git.create_worktree(base_path, worktree_path, branch, repository.default_branch),
           {:ok, task} <- Tasks.set_execution_context(task, worktree_path, branch) do
        {:ok, task, worktree_path, branch}
      end
    end
  end

  defp persist_base_clone_path(%{base_clone_path: path}, path), do: :ok

  defp persist_base_clone_path(repository, path) do
    with {:ok, _} <- Projects.update_repository(repository, %{base_clone_path: path}), do: :ok
  end

  defp charlist_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end
end
