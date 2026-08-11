defmodule CodeLeadWeb.SettingsLive.ProjectTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Agents
  alias CodeLead.Projects

  setup :register_and_log_in_user

  setup do
    %{project: project_fixture()}
  end

  describe "details" do
    test "saves the budget limits", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#project-details-form",
        project: %{name: project.name, budget_limit_cents: "2500", budget_limit_tokens: "100000"}
      )
      |> render_submit()

      reloaded = Projects.get_project!(project.id)
      assert reloaded.budget_limit_cents == 2500
      assert reloaded.budget_limit_tokens == 100_000
    end

    # An empty number input arrives as "", which must clear the limit rather
    # than fail the integer cast.
    test "a blank budget clears the limit", %{conn: conn, project: project} do
      {:ok, _project} = Projects.update_project(project, %{budget_limit_cents: 2500})

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#project-details-form",
        project: %{name: project.name, budget_limit_cents: "", budget_limit_tokens: ""}
      )
      |> render_submit()

      refute Projects.get_project!(project.id).budget_limit_cents
    end
  end

  describe "repositories" do
    test "links a repository", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}/repositories/new")

      view
      |> form("#repository-form",
        repository: %{
          name: "my-app",
          git_url: "git@github.com:me/my-app.git",
          default_branch: "main"
        }
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/projects/#{project.id}")
      assert [repository] = Projects.list_repositories(project.id)
      assert repository.name == "my-app"
    end

    test "edits a repository", %{conn: conn, project: project} do
      repository = repository_fixture(project.id)

      {:ok, view, _html} =
        live(conn, ~p"/settings/projects/#{project.id}/repositories/#{repository.id}/edit")

      view
      |> form("#repository-form",
        repository: %{
          name: repository.name,
          git_url: repository.git_url,
          default_branch: "develop"
        }
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/projects/#{project.id}")
      assert Projects.get_repository!(repository.id).default_branch == "develop"
    end

    test "unlink is blocked while a task targets the repository", %{conn: conn, project: project} do
      repository = repository_fixture(project.id)
      task_fixture(project.id, %{target: :repo, repository_id: repository.id})

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert has_element?(view, "#delete-repository-#{repository.id}[disabled]")
    end

    test "unlinks an unused repository", %{conn: conn, project: project} do
      repository = repository_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view |> element("#delete-repository-#{repository.id}") |> render_click()

      refute has_element?(view, "#repository-row-#{repository.id}")
      assert Projects.list_repositories(project.id) == []
    end
  end

  describe "environment" do
    test "adds a variable without ever showing its value", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}/env/new")

      view
      |> form("#env-form", env: %{key: "GITHUB_TOKEN", value: "ghp-super-secret"})
      |> render_submit()

      assert_patch(view, ~p"/settings/projects/#{project.id}")

      assert has_element?(view, "#env-row-GITHUB_TOKEN")
      refute render(view) =~ "ghp-super-secret"
      assert Projects.env_var(project.id, "GITHUB_TOKEN") == "ghp-super-secret"
    end

    test "rejects an invalid key", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}/env/new")

      view |> form("#env-form", env: %{key: "1BAD-NAME", value: "x"}) |> render_submit()

      assert has_element?(view, "#env-form")
    end

    test "removes a variable", %{conn: conn, project: project} do
      {:ok, _env} = Projects.put_env(project.id, "API_KEY", "s3cret")

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view |> element("#delete-env-API_KEY") |> render_click()

      refute has_element?(view, "#env-row-API_KEY")
      assert Projects.list_env_keys(project.id) == []
    end
  end

  describe "default reviewers" do
    test "saves the set for a work type", %{conn: conn, project: project} do
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#default-reviewers-code-form", %{
        "work_type" => "code",
        "agent_ids" => [to_string(reviewer.id)]
      })
      |> render_submit()

      assert Enum.map(Agents.default_reviewers(project.id, :code), & &1.id) == [reviewer.id]
    end

    test "an empty submit clears the set", %{conn: conn, project: project} do
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      :ok = Agents.set_default_reviewers(project.id, :code, [reviewer.id])

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      # a browser omits unchecked boxes entirely, so no `agent_ids` key arrives
      render_submit(view, "save_reviewers", %{"work_type" => "code"})

      assert Agents.default_reviewers(project.id, :code) == []
    end

    test "a work type with no eligible reviewer routes to the agents page", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert render(view) =~ "No agent can review code work yet"
      refute has_element?(view, "#default-reviewers-code-form")
    end
  end
end
