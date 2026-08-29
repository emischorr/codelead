defmodule CodeLeadWeb.SettingsLive.ProjectTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Agents
  alias CodeLead.Projects

  @moduletag role: :admin

  setup :register_and_log_in_user

  setup do
    %{project: project_fixture()}
  end

  describe "details" do
    test "defaults to blue and saves a chosen color", %{conn: conn, project: project} do
      assert project.color == :blue

      {:ok, view, html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert html =~ "bg-proj-blue"

      view
      |> form("#project-details-form", project: %{name: project.name, color: "violet"})
      |> render_submit()

      assert Projects.get_project!(project.id).color == :violet
    end

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
      _project = set_project_budget!(project, %{budget_limit_cents: 2500})

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#project-details-form",
        project: %{name: project.name, budget_limit_cents: "", budget_limit_tokens: ""}
      )
      |> render_submit()

      refute Projects.get_project!(project.id).budget_limit_cents
    end
  end

  describe "approve defaults" do
    test "saves a finalize mode per target and the artifact path",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#project-finalize-form",
        finalize: %{repo: "squash", folder: "commit_to_path", commit_path: "generated"}
      )
      |> render_submit()

      assert Projects.finalize_defaults(project.id) == %{
               repo: :squash,
               folder: :commit_to_path,
               commit_path: "generated"
             }
    end

    test "leaves unrelated settings keys alone", %{conn: conn, project: project} do
      _project = set_project_budget!(project, %{settings: %{"theme" => "dark"}})

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#project-finalize-form",
        finalize: %{repo: "merge", folder: "artifact", commit_path: ""}
      )
      |> render_submit()

      assert Projects.get_project!(project.id).settings["theme"] == "dark"
    end

    test "the form opens on the mode the finalizer would run", %{conn: conn, project: project} do
      {:ok, _project} = Projects.put_finalize_defaults(project, %{"repo" => "merge"})

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert has_element?(view, ~s(#project-finalize-form option[value="merge"][selected]))
      # Nothing stored for folders, so the built-in default is preselected.
      assert has_element?(view, ~s(#project-finalize-form option[value="artifact"][selected]))
    end
  end

  describe "pr template" do
    test "the form opens prefilled with the built-in default", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert view
             |> element("#project-pr-template-form textarea")
             |> render() =~ "Created by CodeLead"
    end

    test "saves a custom template", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#project-pr-template-form", pr_template: %{template: "## {{title}}"})
      |> render_submit()

      assert Projects.pr_template(project.id) == "## {{title}}"
    end

    test "a blank submit reverts to the built-in default", %{conn: conn, project: project} do
      {:ok, _project} = Projects.put_pr_template(project, "## {{title}}")

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#project-pr-template-form", pr_template: %{template: ""})
      |> render_submit()

      assert Projects.pr_template(project.id) == Projects.default_pr_template()
    end

    test "leaves unrelated settings keys alone", %{conn: conn, project: project} do
      _project = set_project_budget!(project, %{settings: %{"theme" => "dark"}})

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      view
      |> form("#project-pr-template-form", pr_template: %{template: "custom"})
      |> render_submit()

      assert Projects.get_project!(project.id).settings["theme"] == "dark"
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

    test "enabling devcontainer execution stores the env kind and config path", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}/repositories/new")

      view
      |> form("#repository-form",
        repository: %{
          name: "my-app",
          git_url: "git@github.com:me/my-app.git",
          default_branch: "main",
          env_kind: "devcontainer",
          devcontainer_path: ".devcontainer/ci/devcontainer.json"
        }
      )
      |> render_submit()

      assert [repository] = Projects.list_repositories(project.id)
      assert repository.env_kind == :devcontainer
      assert repository.devcontainer_path == ".devcontainer/ci/devcontainer.json"

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")
      assert render(element(view, "#repository-row-#{repository.id}")) =~ "devcontainer"

      # Switching back disables container execution for the repo's tasks.
      {:ok, view, _html} =
        live(conn, ~p"/settings/projects/#{project.id}/repositories/#{repository.id}/edit")

      view
      |> form("#repository-form",
        repository: %{
          name: repository.name,
          git_url: repository.git_url,
          default_branch: repository.default_branch,
          env_kind: "default",
          devcontainer_path: ""
        }
      )
      |> render_submit()

      repository = Projects.get_repository!(repository.id)
      assert repository.env_kind == :default
      assert repository.devcontainer_path == nil

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")
      refute render(element(view, "#repository-row-#{repository.id}")) =~ "devcontainer"
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

    test "the first linked repository is marked default", %{conn: conn, project: project} do
      repository = repository_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert render(element(view, "#repository-row-#{repository.id}")) =~
               "This repo is the default"
    end

    test "a non-default repository offers to become the default", %{conn: conn, project: project} do
      first = repository_fixture(project.id)
      second = repository_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      row = render(element(view, "#repository-row-#{second.id}"))
      assert row =~ "#{first.name} is the default repo."
      assert row =~ "Make this the default"

      view
      |> element("#repository-row-#{second.id} button", "Make this the default")
      |> render_click()

      assert Projects.default_repository(project.id).id == second.id
      assert render(element(view, "#repository-row-#{second.id}")) =~ "This repo is the default"

      refute render(element(view, "#repository-row-#{first.id}")) =~
               "This repo is the default"
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

    test "unchecking encrypt stores and displays a plain value", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}/env/new")

      view
      |> form("#env-form", env: %{key: "ERL_FLAGS", value: "+K true", secret: "false"})
      |> render_submit()

      assert_patch(view, ~p"/settings/projects/#{project.id}")

      assert Projects.env_var(project.id, "ERL_FLAGS") == "+K true"
      assert render(element(view, "#env-row-ERL_FLAGS")) =~ "+K true"
    end

    test "editing a plain entry prefills its real value", %{conn: conn, project: project} do
      {:ok, _env} = Projects.put_env(project.id, "ERL_FLAGS", "+K true", false)

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}/env/ERL_FLAGS/edit")

      assert view
             |> element("#env-form")
             |> render() =~ "+K true"
    end
  end

  describe "agents" do
    test "shows only this project's own agents, not org-wide ones", %{
      conn: conn,
      project: project
    } do
      other_project = project_fixture()
      _org_agent = agent_fixture()
      project_agent = agent_fixture(%{scope: :project, project_id: project.id, name: "Mine"})
      _foreign_agent = agent_fixture(%{scope: :project, project_id: other_project.id})

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert has_element?(view, "#project-agent-row-#{project_agent.id}", "Mine")
      refute render(view) =~ "No project-only agents"
    end

    test "shows the empty state and a link to add one when there are none", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert render(view) =~ "No project-only agents"
      assert has_element?(view, ~s(a[href="#{~p"/settings/agents/new"}"]))
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
