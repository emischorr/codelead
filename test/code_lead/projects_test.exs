defmodule CodeLead.ProjectsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AccountsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Accounts
  alias CodeLead.Projects
  alias CodeLead.Projects.Project
  alias CodeLead.Projects.ProjectEnv

  defp maintainer_scope(project) do
    user = user_fixture()
    membership_fixture(project, user, :maintainer)
    user_scope_fixture(user)
  end

  describe "create_project/2" do
    setup do
      organization_fixture()
      %{scope: user_scope_fixture(user_fixture())}
    end

    test "attaches the organization singleton", %{scope: scope} do
      {:ok, project} = Projects.create_project(scope, %{name: "Fresh"})
      org = CodeLead.Accounts.get_organization!()
      assert %Project{org_id: org_id} = project
      assert org_id == org.id
    end

    test "project names are unique", %{scope: scope} do
      project = project_fixture()
      assert {:error, changeset} = Projects.create_project(scope, %{name: project.name})
      assert %{name: _} = errors_on(changeset)
    end

    test "the creator becomes maintainer in the same transaction", %{scope: scope} do
      {:ok, project} = Projects.create_project(scope, %{name: "Mine"})
      assert Accounts.membership_map(scope.user.id) == %{project.id => :maintainer}
    end

    test "an admin creator gets a membership row too" do
      admin = admin_fixture()
      {:ok, project} = Projects.create_project(user_scope_fixture(admin), %{name: "Theirs"})
      assert Accounts.membership_map(admin.id) == %{project.id => :maintainer}
    end

    test "a failed insert leaves no membership behind", %{scope: scope} do
      project = project_fixture()
      assert {:error, _} = Projects.create_project(scope, %{name: project.name})
      assert Accounts.membership_map(scope.user.id) == %{}
    end

    test "copies the org default budget limits onto the project", %{scope: scope} do
      {:ok, _} =
        Accounts.update_organization(%{
          default_project_budget_limit_cents: 2500,
          default_project_budget_limit_tokens: 1_000_000
        })

      {:ok, project} = Projects.create_project(scope, %{name: "Budgeted"})
      assert project.budget_limit_cents == 2500
      assert project.budget_limit_tokens == 1_000_000
    end

    test "a nil org default yields a nil limit", %{scope: scope} do
      {:ok, project} = Projects.create_project(scope, %{name: "Unbudgeted"})
      assert project.budget_limit_cents == nil
      assert project.budget_limit_tokens == nil
    end

    test "non-admin budget attrs are stripped, the default wins", %{scope: scope} do
      {:ok, _} = Accounts.update_organization(%{default_project_budget_limit_cents: 2500})

      {:ok, project} =
        Projects.create_project(scope, %{name: "Sneaky", budget_limit_cents: 9_999_999})

      assert project.budget_limit_cents == 2500
    end

    test "an admin may set the budget explicitly at creation" do
      {:ok, _} = Accounts.update_organization(%{default_project_budget_limit_cents: 2500})
      admin_scope = user_scope_fixture(admin_fixture())

      {:ok, project} =
        Projects.create_project(admin_scope, %{name: "Custom", budget_limit_cents: 100})

      assert project.budget_limit_cents == 100
    end

    test "refuses without a signed-in user" do
      assert {:error, :unauthorized} = Projects.create_project(nil, %{name: "Nope"})
    end
  end

  describe "update_project/3" do
    test "a maintainer edits details but budget attrs are stripped" do
      project = project_fixture()
      scope = maintainer_scope(project)

      {:ok, updated} =
        Projects.update_project(scope, project, %{name: "Renamed", budget_limit_cents: 500})

      assert updated.name == "Renamed"
      assert updated.budget_limit_cents == nil
    end

    test "an admin edits the budget" do
      project = project_fixture()
      admin_scope = user_scope_fixture(admin_fixture())

      {:ok, updated} = Projects.update_project(admin_scope, project, %{budget_limit_cents: 500})
      assert updated.budget_limit_cents == 500
    end

    test "refuses a member" do
      project = project_fixture()
      user = user_fixture()
      membership_fixture(project, user, :member)

      assert {:error, :unauthorized} =
               Projects.update_project(user_scope_fixture(user), project, %{name: "Nope"})
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

    test "env_kind and devcontainer_path are cast, with blank paths normalized away" do
      project = project_fixture()
      repo = repository_fixture(project.id)

      assert repo.env_kind == :default
      assert repo.devcontainer_path == nil

      assert {:ok, enabled} =
               Projects.update_repository(repo, %{
                 env_kind: :devcontainer,
                 devcontainer_path: ".devcontainer/devcontainer.json"
               })

      assert enabled.env_kind == :devcontainer
      assert enabled.devcontainer_path == ".devcontainer/devcontainer.json"

      # Blank (or whitespace) clears the pinned path back to discovery.
      assert {:ok, discovered} = Projects.update_repository(enabled, %{devcontainer_path: "  "})
      assert discovered.env_kind == :devcontainer
      assert discovered.devcontainer_path == nil

      assert {:ok, disabled} = Projects.update_repository(discovered, %{env_kind: :default})
      assert disabled.env_kind == :default
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

    test "preview ports are unique across the instance, with the app's own port blocked" do
      project = project_fixture()
      other_project = project_fixture()
      first = repository_fixture(project.id, %{preview_port: 4001})

      # Local previews all serve from the app's host, so the rule spans
      # projects, not just one.
      assert {:error, changeset} =
               Projects.update_repository(
                 repository_fixture(other_project.id),
                 %{preview_port: 4001}
               )

      assert "already used by another repository on this instance" in errors_on(changeset).preview_port

      # A repository keeping (or re-submitting) its own port is fine.
      assert {:ok, _repo} = Projects.update_repository(first, %{preview_port: 4001})

      # Undeclared ports coexist freely — the partial index skips NULLs.
      assert {:ok, _repo} = Projects.update_repository(repository_fixture(project.id), %{})

      # The instance's own port (PORT, default 4000) is never a preview port.
      assert {:error, changeset} =
               Projects.update_repository(repository_fixture(project.id), %{preview_port: 4000})

      assert "is the port this CodeLead instance itself listens on" in errors_on(changeset).preview_port
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

    # The listing UI must never decrypt a secret: `list_env_keys/1` never
    # calls `Vault.decrypt!/1` for entries marked secret.
    test "list_env_keys/1 hides the value of secret entries" do
      project = project_fixture()
      {:ok, _} = Projects.put_env(project.id, "API_KEY", "s3cret")

      assert [entry] = Projects.list_env_keys(project.id)
      assert entry.key == "API_KEY"
      assert entry.updated_at
      assert entry.secret == true
      assert entry.value == nil

      # the value is still reachable where it is actually needed
      assert Projects.env_var(project.id, "API_KEY") == "s3cret"
    end

    test "put_env/3 defaults to a secret entry" do
      project = project_fixture()
      {:ok, env} = Projects.put_env(project.id, "API_KEY", "s3cret")

      assert env.secret == true
    end

    test "put_env/4 with secret: false stores the value in plain text" do
      project = project_fixture()
      {:ok, _} = Projects.put_env(project.id, "ERL_FLAGS", "+K true", false)

      %{rows: [[raw_value]]} =
        Repo.query!("SELECT value FROM project_envs WHERE project_id = $1", [project.id])

      assert raw_value == "+K true"
      assert Projects.env_vars(project.id) == [{"ERL_FLAGS", "+K true"}]
      assert Projects.env_var(project.id, "ERL_FLAGS") == "+K true"

      assert [entry] = Projects.list_env_keys(project.id)
      assert entry.secret == false
      assert entry.value == "+K true"
    end
  end

  describe "guarded deletes" do
    test "delete_project/2 refuses while a task belongs to it" do
      project = project_fixture()
      task_fixture(project.id)

      assert Projects.project_usage(project.id) == %{tasks: 1}

      assert {:error, {:has_tasks, 1}} =
               Projects.delete_project(maintainer_scope(project), project)
    end

    test "delete_project/2 takes repositories, env store and memberships with it" do
      project = project_fixture()
      scope = maintainer_scope(project)
      repository_fixture(project.id)
      {:ok, _} = Projects.put_env(project.id, "API_KEY", "s3cret")
      Accounts.subscribe_user(scope.user.id)

      assert {:ok, _project} = Projects.delete_project(scope, project)
      assert Projects.list_repositories(project.id) == []
      assert Projects.list_env_keys(project.id) == []
      assert Accounts.membership_map(scope.user.id) == %{}
      assert_receive {:scope_changed, _user_id}
    end

    test "delete_project/2 refuses a member" do
      project = project_fixture()
      user = user_fixture()
      membership_fixture(project, user, :member)

      assert {:error, :unauthorized} =
               Projects.delete_project(user_scope_fixture(user), project)
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

      {:ok, project} =
        Projects.update_project(maintainer_scope(project), project, %{
          settings: %{"theme" => "dark"}
        })

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

      {:ok, project} =
        Projects.update_project(maintainer_scope(project), project, %{
          settings: %{"theme" => "dark"}
        })

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

  describe "base_clone_path/1" do
    test "trusts a persisted path under the workspace root" do
      project = project_fixture()
      repository = repository_fixture(project.id)
      under_root = CodeLead.Workspace.base_clone_path("elsewhere", 999)
      {:ok, repository} = Projects.update_repository(repository, %{base_clone_path: under_root})

      assert Projects.base_clone_path(repository) == under_root
    end

    test "recomputes when the row is empty or points outside the root" do
      project = project_fixture()
      repository = repository_fixture(project.id)
      canonical = CodeLead.Workspace.base_clone_path(repository.name, repository.id)

      assert Projects.base_clone_path(repository) == canonical

      {:ok, stale} =
        Projects.update_repository(repository, %{base_clone_path: "/old-root/repos/gone"})

      assert Projects.base_clone_path(stale) == canonical
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
