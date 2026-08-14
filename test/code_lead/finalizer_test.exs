defmodule CodeLead.FinalizerTest do
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Finalizer
  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLead.Runtime
  alias CodeLead.Tasks

  setup do
    original = Application.get_env(:code_lead, :forge_req_options)

    on_exit(fn ->
      if original,
        do: Application.put_env(:code_lead, :forge_req_options, original),
        else: Application.delete_env(:code_lead, :forge_req_options)
    end)

    :ok
  end

  defp reviewed_repo_task do
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

    {:ok, context} = LocalSubprocess.provision(task)
    File.write!(Path.join(context.path, "pricing.html"), "<h1>Pricing</h1>\n")

    task =
      Tasks.get_task!(task.id)
      |> executing_task()

    {:ok, task} = Tasks.complete_run(task)
    %{task: task, context: context, repository: repository, project: project}
  end

  describe "resolve_mode/3" do
    test "prefers the task's override, then the project's default" do
      assert Finalizer.resolve_mode(:repo, :squash, :merge) == :squash
      assert Finalizer.resolve_mode(:repo, nil, :merge) == :merge
      assert Finalizer.resolve_mode(:repo, nil, nil) == :pull_request
      assert Finalizer.resolve_mode(:folder, :commit_to_path, nil) == :commit_to_path
      assert Finalizer.resolve_mode(:folder, nil, nil) == :artifact
    end

    test "skips a mode stranded by a target change instead of failing on it" do
      # `target` can still move in Planning, so an override set for the
      # other target is reachable — and must degrade, not crash.
      assert Finalizer.resolve_mode(:repo, :artifact, :squash) == :squash
      assert Finalizer.resolve_mode(:repo, :artifact, nil) == :pull_request
      assert Finalizer.resolve_mode(:folder, :merge, nil) == :artifact
    end
  end

  describe "Runtime.approve/1 for :repo targets" do
    test "commits the remainder, pushes the branch, and moves to Done" do
      %{task: task, context: context} = reviewed_repo_task()

      assert {:ok, task, outcome} = Runtime.approve(task)
      assert task.state == :done
      assert outcome.branch == context.branch_name
      assert outcome.note =~ "pushed"

      # remainder was committed and reached the origin
      {:ok, branches} = Git.remote_branches(context.base_clone_path)
      assert context.branch_name in branches

      {:ok, show} =
        Git.git(context.base_clone_path, [
          "show",
          "origin/#{context.branch_name}:pricing.html"
        ])

      assert show =~ "<h1>Pricing</h1>"

      assert Enum.any?(Tasks.steps(task.id), &(&1.kind == :commit))

      # a file:// origin has no forge convention, so there is no link
      refute Map.has_key?(outcome, :url)
      assert task.pr_url == nil
      assert task.pr_url_kind == nil
    end

    test "a missing worktree keeps the task in Review" do
      %{task: task, context: context} = reviewed_repo_task()
      File.rm_rf!(context.path)

      assert {:error, {:push_failed, :worktree_missing}} = Runtime.approve(task)
      assert Tasks.get_task!(task.id).state == :review
    end

    test "a failed push carries the forge and token facts, keeping the task in Review" do
      %{task: task, context: context} = reviewed_repo_task()
      {:ok, _} = Git.git(context.path, ["remote", "set-url", "origin", "/nope.git"])

      assert {:error, {:push_failed, {:remote, remote}}} = Runtime.approve(task)

      # `create_origin!/0` yields a file:// URL, so :other is the honest
      # classification here; the forge-specific wording is unit-tested in
      # CodeLead.GitTest.
      assert remote.forge == :other
      assert remote.token_present? == false
      assert remote.output =~ "/nope.git"
      assert Tasks.get_task!(task.id).state == :review
    end

    test "prunes the worktree but keeps the remote branch the PR points at" do
      %{task: task, context: context} = reviewed_repo_task()

      assert {:ok, task, %{cleanup: :prune_context}} = Runtime.approve(task)

      refute File.dir?(context.path)
      assert task.worktree_path == nil
      # The branch still names what was pushed, and the PR needs it.
      assert task.branch_name == context.branch_name
      {:ok, branches} = Git.remote_branches(context.base_clone_path)
      assert context.branch_name in branches
    end

    test "a failed finalize prunes nothing" do
      %{task: task, context: context} = reviewed_repo_task()
      {:ok, _} = Git.git(context.path, ["remote", "set-url", "origin", "/nope.git"])

      assert {:error, _reason} = Runtime.approve(task)

      assert File.dir?(context.path)
      assert Tasks.get_task!(task.id).worktree_path == context.path
    end
  end

  describe "Runtime.approve/1 in :merge mode" do
    setup do
      reviewed = reviewed_repo_task()
      {:ok, _project} = Projects.put_finalize_defaults(reviewed.project, %{"repo" => "merge"})
      reviewed
    end

    test "merges the branch into the default branch and deletes it",
         %{task: task, context: context} do
      assert {:ok, task, outcome} = Runtime.approve(task)
      assert task.state == :done
      assert outcome.merged_into == "main"
      assert outcome.note =~ "merged into main"

      {:ok, _} = Git.fetch(context.base_clone_path)
      {:ok, show} = Git.git(context.base_clone_path, ["show", "origin/main:pricing.html"])
      assert show =~ "<h1>Pricing</h1>"

      {:ok, merges} =
        Git.git(context.base_clone_path, ["log", "--merges", "--oneline", "origin/main"])

      assert merges =~ "merge Add pricing page"

      {:ok, branches} = Git.remote_branches(context.base_clone_path)
      refute context.branch_name in branches
    end

    test "prunes the worktree and its staging worktree", %{task: task, context: context} do
      assert {:ok, task, %{cleanup: :prune_context}} = Runtime.approve(task)

      refute File.dir?(context.path)
      refute File.dir?(CodeLead.Workspace.merge_worktree_path(task.id))
      assert task.worktree_path == nil
      assert task.branch_name == context.branch_name
    end

    test "records no forge link for a remote with no forge convention", %{task: task} do
      assert {:ok, task, outcome} = Runtime.approve(task)

      refute Map.has_key?(outcome, :url)
      assert task.pr_url == nil
    end

    test "a conflict keeps the task in Review and leaves the default branch alone",
         %{task: task, context: context, repository: repository} do
      # Both sides touch the same file, so the merge cannot be resolved.
      File.write!(Path.join(context.path, "README.md"), "# Branch\n")
      commit_on_origin!(repository.git_url, "README.md", "# Origin\n")

      assert {:error, {:merge_failed, {:remote, remote}}} = Runtime.approve(task)
      assert remote.base_branch == "main"
      assert Git.merge_refusal(remote.output) == :conflict

      assert Tasks.get_task!(task.id).state == :review
      # Nothing landed, and the staging worktree did not survive the failure.
      {:ok, _} = Git.fetch(context.base_clone_path)
      assert {:error, _} = Git.git(context.base_clone_path, ["show", "origin/main:pricing.html"])
      refute File.dir?(CodeLead.Workspace.merge_worktree_path(task.id))
    end
  end

  describe "Runtime.approve/1 in :squash mode" do
    test "lands the branch as a single commit on the default branch" do
      %{task: task, context: context, project: project} = reviewed_repo_task()
      {:ok, _project} = Projects.put_finalize_defaults(project, %{"repo" => "squash"})

      assert {:ok, task, outcome} = Runtime.approve(task)
      assert task.state == :done
      assert outcome.note =~ "squash-merged into main"

      {:ok, _} = Git.fetch(context.base_clone_path)
      {:ok, log} = Git.git(context.base_clone_path, ["log", "--oneline", "origin/main"])
      # The seed commit plus exactly one squashed commit.
      assert log |> String.split("\n", trim: true) |> length() == 2
      assert log =~ "Add pricing page"

      {:ok, merges} =
        Git.git(context.base_clone_path, ["log", "--merges", "--oneline", "origin/main"])

      assert String.trim(merges) == ""
    end

    test "records the merge commit as the forge link on a GitHub remote" do
      %{task: task, project: project, repository: repository} = reviewed_repo_task()
      {:ok, _project} = Projects.put_finalize_defaults(project, %{"repo" => "squash"})

      {:ok, _repo} =
        Projects.update_repository(repository, %{git_url: "https://github.com/acme/site.git"})

      assert {:ok, task, outcome} = Runtime.approve(task)
      assert outcome.url_kind == :commit
      assert outcome.url =~ "https://github.com/acme/site/commit/"
      assert task.pr_url_kind == :commit
    end
  end

  describe "Runtime.approve/1 for :folder targets" do
    test "returns the artifact path and moves to Done" do
      project = project_fixture()
      agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

      task =
        task_fixture(project.id, %{work_type: :content, target: :folder, agent_id: agent.id})

      {:ok, context} = LocalSubprocess.provision(task)
      File.write!(Path.join(context.path, "output.md"), "# Copy")

      task = executing_task(Tasks.get_task!(task.id))
      {:ok, task} = Tasks.complete_run(task)

      assert {:ok, task, outcome} = Runtime.approve(task)
      assert task.state == :done
      assert outcome.artifact_path == context.path
      assert File.dir?(outcome.artifact_path)
      assert task.pr_url == nil

      # The folder *is* the deliverable, so Done must not tear it down.
      assert outcome.cleanup == :keep_context
      assert File.exists?(Path.join(context.path, "output.md"))
    end

    test "commits the artifact into the project's path when that is the mode" do
      project = project_fixture()
      git_url = create_origin!()
      repository = repository_fixture(project.id, %{git_url: git_url, default_branch: "main"})
      agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

      {:ok, _project} =
        Projects.put_finalize_defaults(project, %{
          "folder" => "commit_to_path",
          "commit_path" => "marketing"
        })

      task =
        task_fixture(project.id, %{
          title: "Hero copy",
          work_type: :content,
          target: :folder,
          repository_id: repository.id,
          agent_id: agent.id
        })

      {:ok, context} = LocalSubprocess.provision(task)
      File.write!(Path.join(context.path, "hero.md"), "# Hero")

      task = executing_task(Tasks.get_task!(task.id))
      {:ok, task} = Tasks.complete_run(task)

      assert {:ok, task, outcome} = Runtime.approve(task)
      assert task.state == :done
      assert outcome.note =~ "marketing/task-#{task.id}-hero-copy"

      repository = Projects.get_repository!(repository.id)

      {:ok, show} =
        Git.git(repository.base_clone_path, [
          "show",
          "origin/#{outcome.branch}:marketing/task-#{task.id}-hero-copy/hero.md"
        ])

      assert show =~ "# Hero"
      assert File.dir?(context.path)
    end

    test "refuses an empty folder — an agent that answered in chat produced nothing" do
      project = project_fixture()
      agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

      task =
        task_fixture(project.id, %{work_type: :content, target: :folder, agent_id: agent.id})

      # Provisioning creates the folder, so it exists and is empty — which
      # is exactly what an agent that wrote no file leaves behind.
      {:ok, context} = LocalSubprocess.provision(task)
      assert File.dir?(context.path)

      task = executing_task(Tasks.get_task!(task.id))
      {:ok, task} = Tasks.complete_run(task)

      assert {:error, :no_artifact} = Runtime.approve(task)
      assert Tasks.get_task!(task.id).state == :review
    end

    test "refuses commit-to-path with no repository, keeping the task in Review" do
      project = project_fixture()
      agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})
      {:ok, _project} = Projects.put_finalize_defaults(project, %{"folder" => "commit_to_path"})

      task =
        task_fixture(project.id, %{work_type: :content, target: :folder, agent_id: agent.id})

      {:ok, _context} = LocalSubprocess.provision(task)
      task = executing_task(Tasks.get_task!(task.id))
      {:ok, task} = Tasks.complete_run(task)

      assert {:error, :no_artifact_repository} = Runtime.approve(task)
      assert Tasks.get_task!(task.id).state == :review
    end
  end

  # The push has to reach a real local origin while the forge classification
  # has to come out GitHub, so the repository's `git_url` is rewritten after
  # provisioning: `finalize/1` classifies from the row, but pushes through the
  # worktree's own remote.
  describe "Runtime.approve/1 persists the forge link" do
    setup do
      %{task: task, project: project, repository: repository} = reviewed_repo_task()

      {:ok, _} =
        Projects.update_repository(repository, %{git_url: "https://github.com/acme/site.git"})

      %{task: task, project: project}
    end

    test "records the opened pull request", %{task: task, project: project} do
      Application.put_env(:code_lead, :forge_req_options, plug: {Req.Test, CodeLead.ForgeStub})
      {:ok, _} = Projects.put_env(project.id, "GITHUB_TOKEN", "gh-token")

      Req.Test.stub(CodeLead.ForgeStub, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"html_url" => "https://github.com/acme/site/pull/7"})
      end)

      assert {:ok, task, outcome} = Runtime.approve(task)
      assert outcome.url_kind == :pull_request
      assert task.pr_url == "https://github.com/acme/site/pull/7"
      assert task.pr_url_kind == :pull_request
    end

    test "falls back to the compare link when no token is configured", %{task: task} do
      assert {:ok, task, outcome} = Runtime.approve(task)
      assert outcome.url_kind == :compare
      assert task.pr_url =~ "https://github.com/acme/site/compare/main..."
      assert task.pr_url_kind == :compare
    end

    test "falls back to the compare link when the forge rejects the request", %{
      task: task,
      project: project
    } do
      Application.put_env(:code_lead, :forge_req_options, plug: {Req.Test, CodeLead.ForgeStub})
      {:ok, _} = Projects.put_env(project.id, "GITHUB_TOKEN", "gh-token")

      Req.Test.stub(CodeLead.ForgeStub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "already exists"})
      end)

      assert {:ok, task, outcome} = Runtime.approve(task)
      assert outcome.url_kind == :compare
      assert task.pr_url_kind == :compare
      assert task.pr_url =~ "/compare/"
    end
  end

  describe "pull request creation" do
    setup do
      Application.put_env(:code_lead, :forge_req_options, plug: {Req.Test, CodeLead.ForgeStub})

      test_pid = self()

      Req.Test.stub(CodeLead.ForgeStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:forge_request, conn.host, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"html_url" => "https://github.com/acme/site/pull/7"})
      end)

      %{project: project_fixture()}
    end

    test "opens a GitHub PR through the API, rendering the default body template", %{
      project: project
    } do
      task = %CodeLead.Tasks.Task{
        id: 1,
        project_id: project.id,
        title: "Add pricing page",
        description: "Three tiers",
        branch_name: "codelead/task-1-add-pricing-page"
      }

      assert {:ok, "https://github.com/acme/site/pull/7"} =
               Finalizer.create_pull_request({:github, "acme", "site"}, "gh-token", task, "main")

      assert_receive {:forge_request, "api.github.com", "/repos/acme/site/pulls", body}
      assert body["head"] == "codelead/task-1-add-pricing-page"
      assert body["base"] == "main"
      assert body["title"] == "Add pricing page"
      assert body["body"] =~ "Three tiers"
      assert body["body"] =~ "Created by CodeLead for task #1."
    end

    test "renders the project's custom PR template", %{project: project} do
      {:ok, project} = Projects.put_pr_template(project, "## {{title}}\n\nBranch: {{branch}}")

      task = %CodeLead.Tasks.Task{
        id: 42,
        project_id: project.id,
        title: "Add pricing page",
        description: "Three tiers",
        branch_name: "codelead/task-42-add-pricing-page"
      }

      assert {:ok, _url} =
               Finalizer.create_pull_request({:github, "acme", "site"}, "gh-token", task, "main")

      assert_receive {:forge_request, "api.github.com", "/repos/acme/site/pulls", body}
      assert body["body"] == "## Add pricing page\n\nBranch: codelead/task-42-add-pricing-page"
    end
  end

  describe "commit_to_path/3" do
    test "pushes the folder artifact to a repo path on an artifact branch" do
      project = project_fixture()
      git_url = create_origin!()
      repository = repository_fixture(project.id, %{git_url: git_url, default_branch: "main"})
      agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

      task =
        task_fixture(project.id, %{
          title: "Hero copy",
          work_type: :content,
          target: :folder,
          agent_id: agent.id
        })

      {:ok, context} = LocalSubprocess.provision(task)
      File.write!(Path.join(context.path, "hero.md"), "# Hero")

      assert {:ok, outcome} = Finalizer.commit_to_path(task, repository.id, "content/landing")
      assert outcome.branch == "codelead/task-#{task.id}-artifact"

      repository = CodeLead.Projects.get_repository!(repository.id)
      {:ok, branches} = Git.remote_branches(repository.base_clone_path)
      assert outcome.branch in branches

      {:ok, show} =
        Git.git(repository.base_clone_path, [
          "show",
          "origin/#{outcome.branch}:content/landing/hero.md"
        ])

      assert show =~ "# Hero"
    end
  end
end
