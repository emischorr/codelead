defmodule CodeLead.FinalizerTest do
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Finalizer
  alias CodeLead.Git
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

  describe "forge/1" do
    test "classifies remotes" do
      assert Finalizer.forge("https://github.com/acme/site.git") == {:github, "acme", "site"}
      assert Finalizer.forge("git@github.com:acme/site.git") == {:github, "acme", "site"}
      assert Finalizer.forge("https://gitlab.com/acme/site") == {:gitlab, "acme", "site"}
      assert Finalizer.forge("file:///tmp/origin.git") == :other
      assert Finalizer.forge("https://git.example.com/acme/site.git") == :other
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
    end

    test "a missing worktree keeps the task in Review" do
      %{task: task, context: context} = reviewed_repo_task()
      File.rm_rf!(context.path)

      assert {:error, {:push_failed, :worktree_missing}} = Runtime.approve(task)
      assert Tasks.get_task!(task.id).state == :review
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
    end
  end

  describe "pull request creation" do
    test "opens a GitHub PR through the API" do
      Application.put_env(:code_lead, :forge_req_options, plug: {Req.Test, CodeLead.ForgeStub})

      test_pid = self()

      Req.Test.stub(CodeLead.ForgeStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:forge_request, conn.host, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"html_url" => "https://github.com/acme/site/pull/7"})
      end)

      task = %CodeLead.Tasks.Task{
        id: 1,
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
