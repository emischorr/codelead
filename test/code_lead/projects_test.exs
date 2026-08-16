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
      second = repository_fixture(project.id)

      assert first.is_default
      refute second.is_default
      assert Projects.default_repository(project.id).id == first.id
      assert length(Projects.list_repositories(project.id)) == 2
    end

    test "set_default_repository/1 moves the default and clears the old one" do
      project = project_fixture()
      first = repository_fixture(project.id)
      second = repository_fixture(project.id)

      assert {:ok, updated_second} = Projects.set_default_repository(second)
      assert updated_second.is_default

      assert Projects.default_repository(project.id).id == second.id
      refute Projects.get_repository!(first.id).is_default
    end

    test "env_kind is derived from the image reference" do
      project = project_fixture()
      repo = repository_fixture(project.id)

      assert repo.env_kind == :default
      assert repo.devcontainer_path == nil
      assert repo.image_ref == nil
      assert repo.dockerfile == nil

      assert {:ok, updated} =
               Projects.update_repository(repo, %{image_ref: "ghcr.io/acme/toolchain:1"})

      assert updated.env_kind == :image
      assert updated.image_ref == "ghcr.io/acme/toolchain:1"

      # Blank (or whitespace) clears both.
      assert {:ok, cleared} = Projects.update_repository(updated, %{image_ref: "  "})
      assert cleared.env_kind == :default
      assert cleared.image_ref == nil

      # A dormant kind set via console is never clobbered by derivation.
      assert {:ok, dormant} =
               Projects.update_repository(cleared, %{
                 env_kind: :devcontainer,
                 devcontainer_path: ".devcontainer"
               })

      assert dormant.env_kind == :devcontainer
      assert {:ok, still} = Projects.update_repository(dormant, %{image_ref: nil})
      assert still.env_kind == :devcontainer
    end

    test "preview_port accepts valid ports, blanks, and rejects out-of-range values" do
      project = project_fixture()
      repo = repository_fixture(project.id)

      assert repo.preview_port == nil

      assert {:ok, updated} = Projects.update_repository(repo, %{preview_port: 5173})
      assert updated.preview_port == 5173

      # An emptied number input arrives as "" and clears the port.
      assert {:ok, cleared} = Projects.update_repository(updated, %{preview_port: ""})
      assert cleared.preview_port == nil

      for invalid <- [0, -1, 65_536, 70_000] do
        assert {:error, changeset} = Projects.update_repository(cleared, %{preview_port: invalid})
        assert %{preview_port: _} = errors_on(changeset)
      end
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

  describe "pr template" do
    test "falls back to the built-in default" do
      project = project_fixture()

      assert Projects.pr_template(project.id) == Projects.default_pr_template()
    end

    test "round-trips a stored template" do
      project = project_fixture()

      {:ok, _project} = Projects.put_pr_template(project, "## {{title}}\n\n{{description}}")

      assert Projects.pr_template(project.id) == "## {{title}}\n\n{{description}}"
    end

    test "leaves unrelated settings keys alone" do
      project = project_fixture()
      {:ok, project} = Projects.update_project(project, %{settings: %{"theme" => "dark"}})

      {:ok, project} = Projects.put_pr_template(project, "custom template")

      assert project.settings["theme"] == "dark"
      assert Projects.pr_template(project.id) == "custom template"
    end

    test "a blank value clears the template back to the built-in default" do
      project = project_fixture()
      {:ok, project} = Projects.put_pr_template(project, "custom template")

      {:ok, _project} = Projects.put_pr_template(project, "")

      assert Projects.pr_template(project.id) == Projects.default_pr_template()
    end
  end

  describe "change_project/2" do
    test "rejects negative budgets" do
      changeset = Projects.change_project(%Project{}, %{name: "x", budget_limit_cents: -1})

      assert %{budget_limit_cents: _} = errors_on(changeset)
    end

    test "color defaults to :blue and only accepts a listed color" do
      assert %Project{color: :blue} = %Project{}

      assert %{valid?: true} = Projects.change_project(%Project{}, %{name: "x", color: "teal"})

      changeset = Projects.change_project(%Project{}, %{name: "x", color: "orange"})
      assert %{color: _} = errors_on(changeset)
    end
  end
end
