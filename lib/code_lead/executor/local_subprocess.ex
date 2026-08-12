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

    forge = Git.forge(repository.git_url)
    token = forge_token(task.project_id, forge)

    with {:ok, _} <- clone(repository.git_url, base_path, forge, token),
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
  def available?([executable | _args]) do
    case System.find_executable(executable) do
      nil -> {:error, {:executable_not_found, executable}}
      _resolved -> :ok
    end
  end

  @impl CodeLead.Executor
  def spawn(%Context{path: path, env: env}, [executable | args], port_opts \\ []) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      resolved ->
        # stderr stays on the BEAM's stderr: for protocol traffic
        # (JSON-RPC over stdout) merged stderr would corrupt frames.
        # Pass :stderr_to_stdout via port_opts when merging is wanted.
        port =
          Port.open(
            {:spawn_executable, resolved},
            [
              :binary,
              :exit_status,
              :hide,
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

  # The base clone's own worktree registry — not the mere presence of a
  # directory — decides whether the path can be reused, because
  # `Workspace.worktree_path/1` is keyed on the task id alone: `mix
  # ecto.reset` reissues ids while the workspace volume survives, so
  # `worktrees/task-<id>` can be a leftover from an earlier generation,
  # and even a worktree of an entirely different repository. Reusing one
  # unchecked runs the agent in the wrong repo.
  defp ensure_worktree(task, repository, base_path) do
    worktree_path = task.worktree_path || Workspace.worktree_path(task.id)

    # The registry alone is not enough: it keeps listing a worktree
    # whose directory was removed until something prunes it.
    with true <- File.dir?(worktree_path),
         {:ok, branch} <- Git.worktree_branch(base_path, worktree_path) do
      adopt_worktree(task, worktree_path, branch)
    else
      _not_ours -> provision_worktree(task, repository, base_path, worktree_path)
    end
  end

  # Persisted on every provisioning, not just the first: a run whose
  # context is missing from the task leaves the diff, the terminal, the
  # reviewers, and the finalizer with nothing to work from. The branch
  # is the one git reports rather than a recomputed slug, so a task
  # renamed between runs keeps the branch its commits are on.
  defp adopt_worktree(task, worktree_path, branch) do
    with {:ok, task} <- Tasks.set_execution_context(task, worktree_path, branch) do
      {:ok, task, worktree_path, branch}
    end
  end

  defp provision_worktree(task, repository, base_path, worktree_path) do
    # A no-op when the path is free; clears the orphan when it is not.
    Git.remove_worktree(base_path, worktree_path)

    with {:ok, _} <- add_worktree(task, repository, base_path, worktree_path) do
      adopt_worktree(task, worktree_path, worktree_branch(task))
    end
  end

  # A recorded branch may carry commits the task still needs, so it is
  # checked out rather than recreated. An unrecorded one can only be an
  # abandoned leftover under the same name, so it goes.
  defp add_worktree(%Task{branch_name: branch} = task, repository, base_path, worktree_path)
       when is_binary(branch) do
    case Git.attach_worktree(base_path, worktree_path, branch) do
      {:ok, path} ->
        {:ok, path}

      {:error, _output} ->
        create_worktree(task, repository, base_path, worktree_path)
    end
  end

  defp add_worktree(task, repository, base_path, worktree_path) do
    Git.delete_branch(base_path, worktree_branch(task))
    create_worktree(task, repository, base_path, worktree_path)
  end

  defp create_worktree(task, repository, base_path, worktree_path) do
    Git.create_worktree(
      base_path,
      worktree_path,
      worktree_branch(task),
      repository.default_branch
    )
  end

  defp worktree_branch(%Task{branch_name: branch}) when is_binary(branch), do: branch

  defp worktree_branch(%Task{id: id, title: title}) do
    "codelead/task-#{id}-#{Workspace.slug(title)}"
  end

  # A bare git failure cannot tell the operator what to do about it, so
  # carry the two facts that decide the remedy: which forge convention
  # applies, and whether a token was actually presented.
  defp clone(git_url, base_path, forge, token) do
    case Git.ensure_clone(git_url, base_path, token: token) do
      {:ok, path} ->
        {:ok, path}

      {:error, output} ->
        {:error, {:remote, %{output: output, forge: forge, token_present?: not is_nil(token)}}}
    end
  end

  # Only GitHub and GitLab remotes have a token convention; anything else
  # (self-hosted forges, file:// remotes) falls back to the host's own
  # git credentials.
  defp forge_token(_project_id, :other), do: nil
  defp forge_token(project_id, {kind, _owner, _repo}), do: Projects.forge_token(project_id, kind)

  defp persist_base_clone_path(%{base_clone_path: path}, path), do: :ok

  defp persist_base_clone_path(repository, path) do
    with {:ok, _} <- Projects.update_repository(repository, %{base_clone_path: path}), do: :ok
  end

  defp charlist_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end
end
