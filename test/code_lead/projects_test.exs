defmodule CodeLead.ProjectsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Projects
  alias CodeLead.Projects.Project
  alias CodeLead.Projects.ProjectEnv

  describe "projects" do
    test "create_project/1 attaches the organization singleton" do
      project = project_fixture()
      org = CodeLead.Accounts.get_organization!()
      assert %Project{org_id: org_id} = project
      assert org_id == org.id
    end

    test "project names are unique" do
      project = project_fixture()
      assert {:error, changeset} = Projects.create_project(%{name: project.name})
      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "repositories" do
    test "link_repository/2 and default_repository/1" do
      project = project_fixture()
      assert Projects.default_repository(project.id) == nil

      first = repository_fixture(project.id)
      _second = repository_fixture(project.id)

      assert Projects.default_repository(project.id).id == first.id
      assert length(Projects.list_repositories(project.id)) == 2
    end

    test "repository names are unique per project" do
      project = project_fixture()
      repo = repository_fixture(project.id)

      assert {:error, changeset} =
               Projects.link_repository(project.id, %{
                 name: repo.name,
                 git_url: "https://example.com/x.git"
               })

      assert %{project_id: _} = errors_on(changeset)
    end
  end

  describe "env store" do
    test "put_env/3 upserts and env_vars/1 decrypts" do
      project = project_fixture()

      assert {:ok, _} = Projects.put_env(project.id, "API_KEY", "s3cret")
      assert {:ok, _} = Projects.put_env(project.id, "API_KEY", "changed")
      assert {:ok, _} = Projects.put_env(project.id, "OTHER", "value")

      assert Projects.env_vars(project.id) == [{"API_KEY", "changed"}, {"OTHER", "value"}]
    end

    test "values are stored encrypted at rest" do
      project = project_fixture()
      {:ok, _} = Projects.put_env(project.id, "API_KEY", "s3cret")

      %{rows: [[raw_value]]} =
        Repo.query!("SELECT value FROM project_envs WHERE project_id = $1", [project.id])

      refute raw_value == "s3cret"
      refute String.contains?(raw_value, "s3cret")
      assert Projects.env_vars(project.id) == [{"API_KEY", "s3cret"}]
    end

    test "invalid env var names are rejected" do
      project = project_fixture()
      assert {:error, changeset} = Projects.put_env(project.id, "1BAD-NAME", "x")
      assert %{key: _} = errors_on(changeset)
    end

    test "delete_env/2 removes the entry" do
      project = project_fixture()
      {:ok, _} = Projects.put_env(project.id, "API_KEY", "s3cret")
      :ok = Projects.delete_env(project.id, "API_KEY")
      assert Projects.env_vars(project.id) == []
      assert Repo.aggregate(ProjectEnv, :count) == 0
    end

    # The listing UI must never decrypt: `list_env_keys/1` selects a bare map
    # so Cloak's load callback never runs.
    test "list_env_keys/1 returns keys without values" do
      project = project_fixture()
      {:ok, _} = Projects.put_env(project.id, "API_KEY", "s3cret")

      assert [entry] = Projects.list_env_keys(project.id)
      assert entry.key == "API_KEY"
      assert entry.updated_at
      refute Map.has_key?(entry, :value)

      # the value is still reachable where it is actually needed
      assert Projects.env_var(project.id, "API_KEY") == "s3cret"
    end
  end

  describe "guarded deletes" do
    test "delete_project/1 refuses while a task belongs to it" do
      project = project_fixture()
      task_fixture(project.id)

      assert Projects.project_usage(project.id) == %{tasks: 1}
      assert {:error, {:has_tasks, 1}} = Projects.delete_project(project)
    end

    test "delete_project/1 takes the repositories and env store with it" do
      project = project_fixture()
      repository_fixture(project.id)
      {:ok, _} = Projects.put_env(project.id, "API_KEY", "s3cret")

      assert {:ok, _project} = Projects.delete_project(project)
      assert Projects.list_repositories(project.id) == []
      assert Projects.list_env_keys(project.id) == []
    end

    test "delete_repository/1 refuses while a task targets it" do
      project = project_fixture()
      repository = repository_fixture(project.id)
      task_fixture(project.id, %{target: :repo, repository_id: repository.id})

      assert {:error, {:has_tasks, 1}} = Projects.delete_repository(repository)
    end

    test "delete_repository/1 unlinks an unused repository" do
      project = project_fixture()
      repository = repository_fixture(project.id)

      assert {:ok, _repository} = Projects.delete_repository(repository)
      assert Projects.list_repositories(project.id) == []
    end
  end

  describe "finalize defaults" do
    test "falls back to nil modes and the built-in commit path" do
      project = project_fixture()

      assert Projects.finalize_defaults(project.id) == %{
               repo: nil,
               folder: nil,
               commit_path: Projects.default_commit_path()
             }
    end

    test "round-trips the stored modes" do
      project = project_fixture()

      {:ok, _project} =
        Projects.put_finalize_defaults(project, %{
          "repo" => "squash",
          "folder" => "commit_to_path",
          "commit_path" => "artifacts/generated"
        })

      assert Projects.finalize_defaults(project.id) == %{
               repo: :squash,
               folder: :commit_to_path,
               commit_path: "artifacts/generated"
             }
    end

    test "ignores a mode the target cannot use, or one that is not a mode at all" do
      project = project_fixture()

      {:ok, _project} =
        Projects.put_finalize_defaults(project, %{"repo" => "artifact", "folder" => "nonsense"})

      assert %{repo: nil, folder: nil} = Projects.finalize_defaults(project.id)
    end

    test "leaves unrelated settings keys alone" do
      project = project_fixture()
      {:ok, project} = Projects.update_project(project, %{settings: %{"theme" => "dark"}})

      {:ok, project} = Projects.put_finalize_defaults(project, %{"repo" => "merge"})

      assert project.settings["theme"] == "dark"
      assert %{repo: :merge} = Projects.finalize_defaults(project.id)
    end

    test "clearing a select returns the target to the built-in default" do
      project = project_fixture()
      {:ok, project} = Projects.put_finalize_defaults(project, %{"repo" => "merge"})

      {:ok, _project} = Projects.put_finalize_defaults(project, %{"repo" => ""})

      assert %{repo: nil} = Projects.finalize_defaults(project.id)
    end
  end

  describe "change_project/2" do
    test "rejects negative budgets" do
      changeset = Projects.change_project(%Project{}, %{name: "x", budget_limit_cents: -1})

      assert %{budget_limit_cents: _} = errors_on(changeset)
    end
  end
end
