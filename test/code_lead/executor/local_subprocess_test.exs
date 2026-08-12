defmodule CodeLead.Executor.LocalSubprocessTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.Context
  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLead.Tasks
  alias CodeLead.Workspace

  defp repo_task_setup do
    project = project_fixture()
    git_url = create_origin!()
    repository = repository_fixture(project.id, %{git_url: git_url, default_branch: "main"})
    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        title: "Add pricing page",
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id
      })

    %{project: project, repository: repository, task: task, git_url: git_url}
  end

  describe "provision/1 for :repo targets" do
    test "creates base clone, worktree, and feature branch; persists paths" do
      %{task: task, repository: repository} = repo_task_setup()

      assert {:ok, %Context{type: :worktree} = context} = LocalSubprocess.provision(task)

      assert File.dir?(context.path)
      assert File.exists?(Path.join(context.path, "README.md"))
      assert context.branch_name == "codelead/task-#{task.id}-add-pricing-page"
      assert context.base_branch == "main"

      task = Tasks.get_task!(task.id)
      assert task.worktree_path == context.path
      assert task.branch_name == context.branch_name

      repository = Projects.get_repository!(repository.id)
      assert repository.base_clone_path == context.base_clone_path

      {:ok, branch_output} = Git.git(context.path, ["branch", "--show-current"])
      assert String.trim(branch_output) == context.branch_name
    end

    test "provisioning twice reuses the same worktree (multi-run)" do
      %{task: task} = repo_task_setup()

      assert {:ok, context1} = LocalSubprocess.provision(task)
      File.write!(Path.join(context1.path, "new.txt"), "work in progress")

      task = Tasks.get_task!(task.id)
      assert {:ok, context2} = LocalSubprocess.provision(task)
      assert context2.path == context1.path
      assert File.exists?(Path.join(context2.path, "new.txt"))
    end

    test "adopts an existing worktree the task has no record of, and persists it" do
      %{task: task} = repo_task_setup()

      {:ok, context} = LocalSubprocess.provision(task)
      File.write!(Path.join(context.path, "earlier.txt"), "work from an earlier run")

      # The directory outlives the record the way it does when the
      # database is dropped and recreated.
      {:ok, task} = Tasks.set_execution_context(Tasks.get_task!(task.id), nil, nil)

      assert {:ok, adopted} = LocalSubprocess.provision(task)
      assert adopted.path == context.path
      assert adopted.branch_name == context.branch_name
      assert File.exists?(Path.join(adopted.path, "earlier.txt"))

      task = Tasks.get_task!(task.id)
      assert task.worktree_path == context.path
      assert task.branch_name == context.branch_name
    end

    test "discards a worktree belonging to another repository" do
      %{task: task, repository: repository} = repo_task_setup()

      # A leftover at this task's path from an earlier database
      # generation, checked out from an unrelated repository.
      other_clone = Path.join([Workspace.root(), "test_origins", "other-#{task.id}"])
      {:ok, _} = Git.ensure_clone(create_origin!(), other_clone)
      orphan = Workspace.worktree_path(task.id)

      {:ok, _} =
        Git.create_worktree(other_clone, orphan, "codelead/task-#{task.id}-stale", "main")

      File.write!(Path.join(orphan, "stale.txt"), "from another repository")

      assert {:ok, context} = LocalSubprocess.provision(task)
      assert context.path == orphan
      refute File.exists?(Path.join(context.path, "stale.txt"))
      assert context.branch_name == "codelead/task-#{task.id}-add-pricing-page"

      {:ok, worktrees} = Git.git(context.base_clone_path, ["worktree", "list"])
      assert worktrees =~ context.path

      assert Tasks.get_task!(task.id).worktree_path == context.path
      refute Projects.get_repository!(repository.id).base_clone_path == other_clone
    end

    test "re-attaches a recorded branch whose worktree directory is gone" do
      %{task: task} = repo_task_setup()
      {:ok, context} = LocalSubprocess.provision(task)

      File.write!(Path.join(context.path, "pricing.html"), "<h1>Pricing</h1>\n")
      {:ok, _} = Git.commit_all(context.path, "Add pricing page")
      File.rm_rf!(context.path)

      assert {:ok, restored} = LocalSubprocess.provision(Tasks.get_task!(task.id))
      assert restored.path == context.path
      assert restored.branch_name == context.branch_name
      assert File.exists?(Path.join(restored.path, "pricing.html"))
    end

    test "project env is injected into the context" do
      %{task: task, project: project} = repo_task_setup()
      {:ok, _} = Projects.put_env(project.id, "API_KEY", "s3cret")

      assert {:ok, context} = LocalSubprocess.provision(task)
      assert {"API_KEY", "s3cret"} in context.env
    end

    test "a stored forge token does not disturb a remote that needs none" do
      %{task: task, project: project} = repo_task_setup()
      {:ok, _} = Projects.put_env(project.id, "GITHUB_TOKEN", "gh-token")

      assert {:ok, %Context{type: :worktree} = context} = LocalSubprocess.provision(task)
      assert File.exists?(Path.join(context.path, "README.md"))
    end

    test "an unreachable remote reports the forge and whether a token was presented" do
      %{task: task, repository: repository} = repo_task_setup()

      {:ok, _} =
        Projects.update_repository(repository, %{
          git_url: "file:///nonexistent/codelead-missing.git"
        })

      assert {:error, {:remote, details}} = LocalSubprocess.provision(Tasks.get_task!(task.id))
      assert details.forge == :other
      refute details.token_present?
      assert details.output =~ "does not appear to be a git repository"
    end
  end

  describe "available?/1" do
    test "resolves an executable on PATH" do
      assert LocalSubprocess.available?(["git"]) == :ok
    end

    test "names the missing executable" do
      assert LocalSubprocess.available?(["definitely-not-a-real-binary-xyz", "acp"]) ==
               {:error, {:executable_not_found, "definitely-not-a-real-binary-xyz"}}
    end
  end

  describe "provision/1 for :folder targets" do
    test "creates the task folder" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})

      assert {:ok, %Context{type: :folder} = context} = LocalSubprocess.provision(task)
      assert File.dir?(context.path)
      assert context.base_clone_path == nil
    end
  end

  describe "spawn/3" do
    test "runs a command inside the context with env injected" do
      project = project_fixture()
      {:ok, _} = Projects.put_env(project.id, "GREETING", "hello-from-env")
      task = task_fixture(project.id, %{work_type: :file})

      {:ok, context} = LocalSubprocess.provision(task)

      assert {:ok, port} =
               LocalSubprocess.spawn(context, ["sh", "-c", "pwd; printf %s $GREETING"])

      output = collect_port_output(port)
      assert output =~ Path.basename(context.path)
      assert output =~ "hello-from-env"
    end

    test "unknown executable returns an error" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :file})
      {:ok, context} = LocalSubprocess.provision(task)

      assert {:error, {:executable_not_found, _}} =
               LocalSubprocess.spawn(context, ["definitely-not-a-real-binary-xyz"])
    end
  end

  describe "diff / commit / push round trip" do
    test "worktree changes diff against the branch base and push to origin" do
      %{task: task} = repo_task_setup()
      {:ok, context} = LocalSubprocess.provision(task)

      # Fresh worktree: empty diff.
      assert {:ok, ""} = Git.diff(context.path, context.base_branch)

      File.write!(Path.join(context.path, "pricing.html"), "<h1>Pricing</h1>\n")
      {:ok, diff} = Git.diff(context.path, context.base_branch)
      assert diff =~ "pricing.html"
      assert diff =~ "<h1>Pricing</h1>"

      assert {:ok, _} = Git.commit_all(context.path, "Add pricing page")
      assert :noop = Git.commit_all(context.path, "nothing to do")

      # Committed work still diffs against the branch base.
      {:ok, diff_after_commit} = Git.diff(context.path, context.base_branch)
      assert diff_after_commit =~ "pricing.html"

      assert {:ok, _} = Git.push(context.path, context.branch_name)
      {:ok, branches} = Git.remote_branches(context.base_clone_path)
      assert context.branch_name in branches
    end
  end

  describe "teardown/2" do
    test "keep: true leaves everything in place" do
      %{task: task} = repo_task_setup()
      {:ok, context} = LocalSubprocess.provision(task)

      assert :ok = LocalSubprocess.teardown(context, keep: true)
      assert File.dir?(context.path)
    end

    test "keep: false removes worktree and deletes the branch" do
      %{task: task} = repo_task_setup()
      {:ok, context} = LocalSubprocess.provision(task)

      assert :ok = LocalSubprocess.teardown(context, keep: false)
      refute File.dir?(context.path)

      {:ok, branches} = Git.git(context.base_clone_path, ["branch", "--list"])
      refute branches =~ context.branch_name
    end

    test "keep: false removes a task folder" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})
      {:ok, context} = LocalSubprocess.provision(task)
      File.write!(Path.join(context.path, "draft.md"), "# Draft")

      assert :ok = LocalSubprocess.teardown(context, keep: false)
      refute File.dir?(context.path)
    end
  end

  defp collect_port_output(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> collect_port_output(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    after
      5_000 -> flunk("port produced no output; got so far: #{inspect(acc)}")
    end
  end
end
