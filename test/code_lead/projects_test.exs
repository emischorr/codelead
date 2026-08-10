defmodule CodeLead.ProjectsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures

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
  end
end
