defmodule CodeLead.Finalizer do
  @moduledoc """
  The system executor behind Approve → Done. By target:

  - `:repo` — commit any remainder in the worktree, push the feature
    branch, and (GitHub/GitLab remotes) open a PR/MR via API when a
    forge token is present in the project env store, otherwise return
    a compare URL. **Never merges to main** — merging is releasing and
    stays out of scope.
  - `:folder` — the task folder is the downloadable artifact;
    `commit_to_path/3` optionally pushes it to a repo path on a
    `codelead/task-<id>-artifact` branch.
  """

  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @type outcome :: %{
          optional(:url) => String.t(),
          optional(:branch) => String.t(),
          optional(:artifact_path) => String.t(),
          note: String.t()
        }

  @doc """
  Finalizes the task's work product. Called before the Review → Done
  transition; a failure keeps the task in Review.
  """
  @spec finalize(Task.t()) :: {:ok, outcome()} | {:error, term()}
  def finalize(%Task{target: :repo} = task) do
    repository = Projects.get_repository!(task.repository_id)

    with :ok <- ensure_context(task),
         _commit = Git.commit_all(task.worktree_path, "CodeLead: finalize #{task.title}"),
         {:ok, _output} <- Git.push(task.worktree_path, task.branch_name) do
      {:ok, forge_outcome(task, repository)}
    else
      {:error, reason} -> {:error, {:push_failed, reason}}
    end
  end

  def finalize(%Task{target: :folder} = task) do
    path = Workspace.task_folder(task.id)

    if File.dir?(path) do
      {:ok, %{artifact_path: path, note: "artifact ready for download"}}
    else
      {:error, :no_artifact}
    end
  end

  @doc """
  Commits a folder task's artifact files into a repository path on a
  fresh `codelead/task-<id>-artifact` branch and pushes it.
  """
  @spec commit_to_path(Task.t(), pos_integer(), String.t()) ::
          {:ok, outcome()} | {:error, term()}
  def commit_to_path(%Task{target: :folder} = task, repository_id, dest_path) do
    repository = Projects.get_repository!(repository_id)
    artifact = Workspace.task_folder(task.id)
    branch = "codelead/task-#{task.id}-artifact"

    base_path =
      repository.base_clone_path || Workspace.base_clone_path(repository.name, repository.id)

    worktree = Path.join([Workspace.root(), "worktrees", "task-#{task.id}-artifact"])

    with {:ok, _} <- Git.ensure_clone(repository.git_url, base_path),
         {:ok, _} <- persist_base_clone_path(repository, base_path),
         {:ok, _} <- Git.create_worktree(base_path, worktree, branch, repository.default_branch),
         dest = Path.join(worktree, dest_path),
         :ok <- File.mkdir_p(dest),
         {:ok, _files} <- File.cp_r(artifact, dest),
         _commit = Git.commit_all(worktree, "CodeLead: artifact of #{task.title}"),
         {:ok, _} <- Git.push(worktree, branch) do
      Git.remove_worktree(base_path, worktree)
      {:ok, %{branch: branch, note: "artifact committed to #{dest_path} on #{branch}"}}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @doc """
  Classifies a git remote URL: `{:github, owner, repo}`,
  `{:gitlab, owner, repo}`, or `:other`.
  """
  @spec forge(String.t()) :: {:github | :gitlab, String.t(), String.t()} | :other
  def forge(git_url) do
    case Regex.run(
           ~r{(?:https://|git@)(github\.com|gitlab\.com)[:/]([^/]+)/(.+?)(?:\.git)?/?$},
           git_url
         ) do
      ["" <> _match, "github.com", owner, repo] -> {:github, owner, repo}
      [_match, "gitlab.com", owner, repo] -> {:gitlab, owner, repo}
      _no_match -> :other
    end
  end

  @doc """
  Opens a PR (GitHub) or MR (GitLab) for the pushed branch. The token
  comes from the project env store (`GITHUB_TOKEN` / `GITLAB_TOKEN`).
  """
  @spec create_pull_request(
          {:github | :gitlab, String.t(), String.t()},
          String.t(),
          Task.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def create_pull_request({:github, owner, repo}, token, task, base_branch) do
    request(
      url: "https://api.github.com/repos/#{owner}/#{repo}/pulls",
      auth: {:bearer, token},
      json: %{
        title: task.title,
        head: task.branch_name,
        base: base_branch,
        body: pr_body(task)
      }
    )
    |> parse_url("html_url")
  end

  def create_pull_request({:gitlab, owner, repo}, token, task, base_branch) do
    project = URI.encode_www_form("#{owner}/#{repo}")

    request(
      url: "https://gitlab.com/api/v4/projects/#{project}/merge_requests",
      headers: [{"PRIVATE-TOKEN", token}],
      json: %{
        title: task.title,
        source_branch: task.branch_name,
        target_branch: base_branch,
        description: pr_body(task)
      }
    )
    |> parse_url("web_url")
  end

  ## Internals

  defp persist_base_clone_path(%{base_clone_path: path} = repository, path), do: {:ok, repository}

  defp persist_base_clone_path(repository, path) do
    Projects.update_repository(repository, %{base_clone_path: path})
  end

  defp forge_outcome(task, repository) do
    case forge(repository.git_url) do
      :other ->
        %{branch: task.branch_name, note: "branch pushed; open a PR on your forge manually"}

      {kind, _owner, _repo} = forge ->
        case forge_token(task.project_id, kind) do
          nil ->
            %{
              url: compare_url(forge, repository.default_branch, task.branch_name),
              branch: task.branch_name,
              note: "branch pushed; no #{token_var(kind)} in the project env — compare link"
            }

          token ->
            pull_request_outcome(forge, token, task, repository)
        end
    end
  end

  defp pull_request_outcome({kind, _owner, _repo} = forge, token, task, repository) do
    case create_pull_request(forge, token, task, repository.default_branch) do
      {:ok, url} ->
        %{url: url, branch: task.branch_name, note: "#{kind} pull request opened"}

      {:error, reason} ->
        %{
          url: compare_url(forge, repository.default_branch, task.branch_name),
          branch: task.branch_name,
          note: "branch pushed; PR creation failed (#{inspect(reason)}) — compare link"
        }
    end
  end

  defp compare_url({:github, owner, repo}, base, branch),
    do: "https://github.com/#{owner}/#{repo}/compare/#{base}...#{branch}"

  defp compare_url({:gitlab, owner, repo}, base, branch),
    do: "https://gitlab.com/#{owner}/#{repo}/-/compare/#{base}...#{branch}"

  defp forge_token(project_id, kind) do
    project_id
    |> Projects.env_vars()
    |> Enum.find_value(fn {key, value} -> if key == token_var(kind), do: value end)
  end

  defp token_var(:github), do: "GITHUB_TOKEN"
  defp token_var(:gitlab), do: "GITLAB_TOKEN"

  defp pr_body(task) do
    """
    #{task.description || ""}

    ---
    Created by CodeLead for task ##{task.id}.
    """
  end

  defp ensure_context(%Task{worktree_path: nil}), do: {:error, :no_worktree}
  defp ensure_context(%Task{branch_name: nil}), do: {:error, :no_branch}

  defp ensure_context(%Task{worktree_path: path}) do
    if File.dir?(path), do: :ok, else: {:error, :worktree_missing}
  end

  defp request(opts) do
    opts =
      Keyword.merge(
        [method: :post, receive_timeout: 30_000],
        opts ++ Application.get_env(:code_lead, :forge_req_options, [])
      )

    Req.request(opts)
  end

  defp parse_url({:ok, %Req.Response{status: status, body: body}}, key)
       when status in [200, 201] do
    {:ok, body[key]}
  end

  defp parse_url({:ok, %Req.Response{status: status, body: body}}, _key),
    do: {:error, {:http_error, status, body}}

  defp parse_url({:error, exception}, _key), do: {:error, exception}
end
