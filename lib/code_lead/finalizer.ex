defmodule CodeLead.Finalizer do
  @moduledoc """
  The system executor behind Approve → Done, dispatched on the task's
  `target` and its resolved finalize mode (`resolve_mode/3`).

  `:repo` always commits any remainder and pushes the feature branch
  first, then:

  - `:pull_request` — on GitHub/GitLab open a PR/MR via API when a forge
    token is present in the project env store, otherwise return a
    compare URL. Nothing is merged and the remote branch stays.
  - `:merge` / `:squash` — merge the branch into the repository's
    default branch in a disposable worktree and push it, then delete the
    remote feature branch.

  `:folder` hands the task folder over as the downloadable artifact
  (`:artifact`) or commits it to a repository path on a
  `codelead/task-<id>-artifact` branch (`:commit_to_path`).

  **Merging is git, never a forge action** — no Merge button, no PR
  close, no check gating — so it works against any remote. Releasing
  (tags, changelogs, deploys) stays out of scope.

  Every outcome carries `cleanup:`, which tells the finalize stage
  whether the execution context may be torn down. It lives on the
  outcome rather than on the workflow edge because it depends on the
  mode and on the finalize having succeeded — see architecture spec
  §4.1.

  Git transport uses the same forge token: it is resolved here and passed
  to `CodeLead.Git`, which injects it through an ephemeral credential
  helper. See `CodeLead.Git` for why nothing is written to `.git/config`.
  """

  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @type outcome :: %{
          optional(:url) => String.t(),
          optional(:url_kind) => Task.url_kind(),
          optional(:branch) => String.t(),
          optional(:merged_into) => String.t(),
          optional(:artifact_path) => String.t(),
          cleanup: :keep_context | :prune_context,
          note: String.t()
        }

  @doc """
  Picks the mode to finalize with: the task's override, else the
  project's default for this target, else the target's built-in.

  Pure and DB-free so the UI can label the Approve button with the very
  value the finalizer will run. A mode belonging to the *other* target
  is skipped rather than rejected — `target` can still change in
  Planning, which can strand an override that was valid when it was set.
  """
  @spec resolve_mode(Task.target(), Task.finalize_mode() | nil, Task.finalize_mode() | nil) ::
          Task.finalize_mode()
  def resolve_mode(target, task_mode, project_mode) do
    allowed = Task.finalize_modes(target)

    Enum.find([task_mode, project_mode], Task.default_finalize_mode(target), &(&1 in allowed))
  end

  @doc """
  Finalizes the task's work product in the given mode. Called before the
  Review → Done transition; a failure keeps the task in Review.

  A git transport failure carries the facts that decide the remedy —
  which forge convention applies, whether a token was presented, and for
  a merge which branch was being written — so the caller can render
  `CodeLead.Git.remote_failure/4` or `merge_failure/4` instead of a raw
  git dump.
  """
  @spec finalize(Task.t(), Task.finalize_mode()) :: {:ok, outcome()} | {:error, term()}
  def finalize(%Task{target: :repo} = task, :pull_request) do
    repository = Projects.get_repository!(task.repository_id)
    forge = Git.forge(repository.git_url)
    token = forge_token(task.project_id, forge)

    case commit_and_push(task, token) do
      {:ok, _pushed} -> {:ok, forge_outcome(task, repository, forge, token)}
      {:error, reason} -> {:error, push_failure(reason, forge, token)}
    end
  end

  def finalize(%Task{target: :repo} = task, mode) when mode in [:merge, :squash] do
    repository = Projects.get_repository!(task.repository_id)
    forge = Git.forge(repository.git_url)
    token = forge_token(task.project_id, forge)
    base_path = base_clone_path(repository)
    staging = Workspace.merge_worktree_path(task.id)

    try do
      merge_and_push(task, repository, mode, base_path, staging, token)
    after
      # Also on failure: a conflicted merge leaves the worktree mid-state,
      # and discarding the whole directory is simpler than `merge --abort`.
      Git.remove_worktree(base_path, staging)
    end
    |> case do
      {:ok, sha} ->
        # Best effort. The merge has already landed, so a refusal here
        # must not undo Done — a leftover branch on the forge is cosmetic.
        _ = Git.delete_remote_branch(base_path, task.branch_name, token: token)
        {:ok, merge_outcome(task, repository, forge, mode, sha)}

      {:error, reason} ->
        {:error, merge_failure(reason, repository.default_branch, forge, token)}
    end
  end

  def finalize(%Task{target: :folder} = task, :artifact) do
    path = Workspace.task_folder(task.id)

    # Existence is not enough: the folder is provisioned before the run,
    # so an agent that answered in chat without writing a file leaves one
    # behind that is present and empty. Handing that over as a download
    # would promise something the zip cannot deliver.
    case Workspace.artifact_files(path) do
      [] ->
        {:error, :no_artifact}

      files ->
        {:ok,
         %{
           artifact_path: path,
           cleanup: :keep_context,
           note: "artifact ready for download (#{file_count(files)})"
         }}
    end
  end

  def finalize(%Task{target: :folder, repository_id: nil}, :commit_to_path) do
    {:error, :no_artifact_repository}
  end

  def finalize(%Task{target: :folder} = task, :commit_to_path) do
    %{commit_path: commit_path} = Projects.finalize_defaults(task.project_id)
    dest = Path.join(commit_path, "task-#{task.id}-#{Workspace.slug(task.title)}")

    commit_to_path(task, task.repository_id, dest)
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

    base_path = base_clone_path(repository)
    worktree = Path.join([Workspace.root(), "worktrees", "task-#{task.id}-artifact"])
    token = forge_token(task.project_id, Git.forge(repository.git_url))

    with {:ok, _} <- Git.ensure_clone(repository.git_url, base_path, token: token),
         {:ok, _} <- persist_base_clone_path(repository, base_path),
         {:ok, _} <- Git.create_worktree(base_path, worktree, branch, repository.default_branch),
         dest = Path.join(worktree, dest_path),
         :ok <- File.mkdir_p(dest),
         {:ok, _files} <- File.cp_r(artifact, dest),
         _commit = Git.commit_all(worktree, "CodeLead: artifact of #{task.title}"),
         {:ok, _} <- Git.push(worktree, branch, token: token) do
      Git.remove_worktree(base_path, worktree)

      {:ok,
       %{
         branch: branch,
         # The task folder is the artifact's home; committing a copy
         # elsewhere does not make it disposable.
         cleanup: :keep_context,
         note: "artifact committed to #{dest_path} on #{branch}"
       }}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @doc """
  Opens a PR (GitHub) or MR (GitLab) for the pushed branch. The token
  comes from the project env store (`GITHUB_TOKEN` / `GITLAB_TOKEN`);
  the body is rendered from the project's PR template
  (`CodeLead.Projects.pr_template/1`).
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

  defp commit_and_push(task, token) do
    with :ok <- ensure_context(task) do
      # `:noop` when the agent already committed everything — not a failure.
      _commit = Git.commit_all(task.worktree_path, "CodeLead: finalize #{task.title}")
      Git.push(task.worktree_path, task.branch_name, token: token)
    end
  end

  # The feature branch is pushed *before* the merge and deleted *after*
  # it, so a conflict or a rejected push loses no work — the same order a
  # forge's "Merge and delete branch" uses.
  #
  # The *local* branch ref is what gets merged: the task's worktree is a
  # linked worktree of this very clone, so its commits are visible as
  # `refs/heads/<branch>` here regardless of what the remote accepted.
  defp merge_and_push(task, repository, mode, base_path, staging, token) do
    with {:ok, _pushed} <- commit_and_push(task, token),
         {:ok, _fetched} <- Git.fetch(base_path, token: token),
         {:ok, _staging} <-
           Git.create_detached_worktree(base_path, staging, repository.default_branch),
         {:ok, _merged} <-
           Git.merge(staging, task.branch_name,
             strategy: mode,
             message: merge_message(task, mode)
           ),
         {:ok, sha} <- Git.head_sha(staging),
         {:ok, _pushed} <-
           Git.push_ref(staging, "HEAD", repository.default_branch, token: token) do
      {:ok, sha}
    else
      # The branch adding nothing is not a failure: the work already
      # landed on the default branch, so Done is simply true.
      :noop -> Git.head_sha(staging)
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_clone_path(%{base_clone_path: nil, name: name, id: id}),
    do: Workspace.base_clone_path(name, id)

  defp base_clone_path(%{base_clone_path: path}), do: path

  defp merge_message(%Task{id: id, title: title}, :squash),
    do: "CodeLead: #{title} (task ##{id})"

  defp merge_message(%Task{id: id, title: title}, :merge),
    do: "CodeLead: merge #{title} (task ##{id})"

  # Git output alone cannot tell the operator what to do about it, so a
  # push failure is enriched the way `LocalSubprocess.provision/1`
  # enriches a clone failure — both render through
  # `Git.remote_failure/4`. The `ensure_context/1` atoms carry no output
  # and pass through unchanged.
  defp push_failure(output, forge, token) when is_binary(output) do
    {:push_failed, {:remote, %{output: output, forge: forge, token_present?: not is_nil(token)}}}
  end

  defp push_failure(reason, _forge, _token), do: {:push_failed, reason}

  # Same shape as `push_failure/3`, plus the branch being written — a
  # merge failure's remedy usually names it ("main moved", "main is
  # protected").
  defp merge_failure(output, base_branch, forge, token) when is_binary(output) do
    {:merge_failed,
     {:remote,
      %{
        output: output,
        forge: forge,
        token_present?: not is_nil(token),
        base_branch: base_branch
      }}}
  end

  defp merge_failure(reason, _base_branch, _forge, _token), do: {:merge_failed, reason}

  defp merge_outcome(task, repository, forge, mode, sha) do
    base = repository.default_branch

    %{
      branch: task.branch_name,
      merged_into: base,
      cleanup: :prune_context,
      note: "#{merge_verb(mode)} into #{base}; feature branch deleted"
    }
    |> put_commit_url(forge, sha)
  end

  defp file_count([_one]), do: "1 file"
  defp file_count(files), do: "#{length(files)} files"

  defp merge_verb(:squash), do: "squash-merged"
  defp merge_verb(:merge), do: "merged"

  # A remote with no forge convention has no URL scheme to build on, so
  # the outcome carries no link rather than a guessed one.
  defp put_commit_url(outcome, :other, _sha), do: outcome

  defp put_commit_url(outcome, forge, sha) do
    Map.merge(outcome, %{url: commit_url(forge, sha), url_kind: :commit})
  end

  defp commit_url({:github, owner, repo}, sha),
    do: "https://github.com/#{owner}/#{repo}/commit/#{sha}"

  defp commit_url({:gitlab, owner, repo}, sha),
    do: "https://gitlab.com/#{owner}/#{repo}/-/commit/#{sha}"

  defp persist_base_clone_path(%{base_clone_path: path} = repository, path), do: {:ok, repository}

  defp persist_base_clone_path(repository, path) do
    Projects.update_repository(repository, %{base_clone_path: path})
  end

  defp forge_outcome(task, _repository, :other, _token) do
    %{
      branch: task.branch_name,
      cleanup: :prune_context,
      note: "branch pushed; open a PR on your forge manually"
    }
  end

  defp forge_outcome(task, repository, {kind, _owner, _repo} = forge, nil) do
    %{
      url: compare_url(forge, repository.default_branch, task.branch_name),
      url_kind: :compare,
      branch: task.branch_name,
      cleanup: :prune_context,
      note: "branch pushed; no #{Git.token_var(kind)} in the project env — compare link"
    }
  end

  defp forge_outcome(task, repository, forge, token) do
    pull_request_outcome(forge, token, task, repository)
  end

  defp pull_request_outcome({kind, _owner, _repo} = forge, token, task, repository) do
    case create_pull_request(forge, token, task, repository.default_branch) do
      {:ok, url} ->
        %{
          url: url,
          url_kind: request_kind(kind),
          branch: task.branch_name,
          cleanup: :prune_context,
          note: "#{kind} pull request opened"
        }

      {:error, reason} ->
        %{
          url: compare_url(forge, repository.default_branch, task.branch_name),
          url_kind: :compare,
          branch: task.branch_name,
          cleanup: :prune_context,
          # The note is persisted and rendered on the Done card, and a
          # forge error body can echo the credential back.
          note:
            "branch pushed; PR creation failed (#{Git.redact(inspect(reason))}) — compare link"
        }
    end
  end

  defp request_kind(:github), do: :pull_request
  defp request_kind(:gitlab), do: :merge_request

  defp compare_url({:github, owner, repo}, base, branch),
    do: "https://github.com/#{owner}/#{repo}/compare/#{base}...#{branch}"

  defp compare_url({:gitlab, owner, repo}, base, branch),
    do: "https://gitlab.com/#{owner}/#{repo}/-/compare/#{base}...#{branch}"

  defp forge_token(_project_id, :other), do: nil
  defp forge_token(project_id, {kind, _owner, _repo}), do: Projects.forge_token(project_id, kind)

  defp pr_body(task) do
    task.project_id
    |> Projects.pr_template()
    |> String.replace("{{title}}", task.title || "")
    |> String.replace("{{description}}", task.description || "")
    |> String.replace("{{task_id}}", to_string(task.id))
    |> String.replace("{{branch}}", task.branch_name || "")
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
