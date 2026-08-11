defmodule CodeLeadWeb.SetupLiveTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeLead.Accounts
  alias CodeLead.Agents
  alias CodeLead.Projects

  @moduletag :setup_pending

  @password "a-very-long-password"

  describe "admin step" do
    test "opens on the admin step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      assert has_element?(view, "#setup-admin-form")
      refute has_element?(view, "#setup-provider-form")
    end

    test "shows validation errors for a short password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("#setup-admin-form", user: %{email: "admin@example.com", password: "short"})
        |> render_change()

      assert html =~ "should be at least 12 character"
    end

    test "posting the admin form creates the organization, the admin, and a session", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/setup/admin", %{
          "organization" => %{"name" => "Acme"},
          "user" => %{"email" => "admin@example.com", "password" => @password}
        })

      assert redirected_to(conn) == ~p"/setup"
      assert get_session(conn, :user_token)

      assert %{name: "Acme"} = Accounts.get_organization!()

      assert %{role: :admin, confirmed_at: %DateTime{}} =
               Accounts.get_user_by_email("admin@example.com")

      refute Accounts.setup_done?()
    end

    test "retrying after a rejected password still applies the organization name", %{conn: conn} do
      post(conn, ~p"/setup/admin", %{
        "organization" => %{"name" => "First Try"},
        "user" => %{"email" => "admin@example.com", "password" => "short"}
      })

      refute Accounts.any_users?()

      post(conn, ~p"/setup/admin", %{
        "organization" => %{"name" => "Second Try"},
        "user" => %{"email" => "admin@example.com", "password" => @password}
      })

      assert %{name: "Second Try"} = Accounts.get_organization!()
      assert Accounts.any_users?()
    end

    test "a blank organization name falls back to the default", %{conn: conn} do
      post(conn, ~p"/setup/admin", %{
        "organization" => %{"name" => "  "},
        "user" => %{"email" => "admin@example.com", "password" => @password}
      })

      assert %{name: "CodeLead"} = Accounts.get_organization!()
    end

    test "a second admin registration is refused", %{conn: conn} do
      params = %{
        "organization" => %{"name" => "Acme"},
        "user" => %{"email" => "admin@example.com", "password" => @password}
      }

      post(conn, ~p"/setup/admin", params)
      conn = post(conn, ~p"/setup/admin", put_in(params, ["user", "email"], "two@example.com"))

      assert redirected_to(conn) == ~p"/setup"
      refute Accounts.get_user_by_email("two@example.com")
    end
  end

  describe "provider step" do
    setup :with_admin

    test "opens on the provider step and creates a provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      assert has_element?(view, "#setup-provider-form")

      view
      |> form("#setup-provider-form",
        provider: %{name: "Anthropic", kind: "anthropic_api", credential: "sk-test"}
      )
      |> render_submit()

      assert [%{name: "Anthropic", kind: :anthropic_api, config: %{"api_key" => "sk-test"}}] =
               Agents.list_providers()

      assert has_element?(view, "#setup-project-form")
    end

    test "a blank credential keeps the user on the step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("#setup-provider-form",
          provider: %{name: "Anthropic", kind: "anthropic_api", credential: "  "}
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Agents.list_providers() == []
    end

    test "an ollama endpoint lands under the endpoint key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#setup-provider-form",
        provider: %{name: "Ollama", kind: "ollama", credential: "http://localhost:11434"}
      )
      |> render_submit()

      assert [%{config: %{"endpoint" => "http://localhost:11434"}}] = Agents.list_providers()
    end
  end

  describe "project step" do
    setup [:with_admin, :with_provider]

    test "creates a project with a repository", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#setup-project-form",
        project: %{
          name: "Acme Site",
          repo_name: "acme-site",
          git_url: "https://example.com/acme.git",
          default_branch: "main"
        }
      )
      |> render_submit()

      assert [project] = Projects.list_projects()
      assert project.name == "Acme Site"
      assert [%{name: "acme-site"}] = Projects.list_repositories(project.id)
      assert has_element?(view, "#setup-agent-form")
    end

    test "a rejected repository rolls the project back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#setup-project-form",
        project: %{name: "Acme Site", repo_name: "", git_url: "https://example.com/acme.git"}
      )
      |> render_submit()

      assert Projects.list_projects() == []
      assert has_element?(view, "#setup-project-form")
    end

    test "skipping moves on to the agent step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> element("#setup-skip-project") |> render_click()

      assert Projects.list_projects() == []
      assert has_element?(view, "#setup-agent-form")
    end

    test "an access token lands in the project env store under the forge key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#setup-project-form",
        project: %{
          name: "Acme Site",
          repo_name: "acme-site",
          git_url: "https://github.com/acme/site.git",
          default_branch: "main",
          access_token: "github_pat_11ABCDEFG0abcdefghijklmnop"
        }
      )
      |> render_submit()

      assert [project] = Projects.list_projects()

      assert Projects.env_var(project.id, "GITHUB_TOKEN") ==
               "github_pat_11ABCDEFG0abcdefghijklmnop"
    end

    test "a token the forge rejects is reported without losing the project", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("#setup-project-form",
          project: %{
            name: "Acme Site",
            repo_name: "acme-site",
            git_url: "https://github.com/acme/reject.git",
            default_branch: "main",
            access_token: "github_pat_11ABCDEFG0abcdefghijklmnop"
          }
        )
        |> render_submit()

      assert html =~ "github.com rejected the GITHUB_TOKEN"
      assert html =~ "Invalid username or token"

      # The project still exists, so the wizard moves on rather than
      # trapping the operator on a step they cannot complete offline.
      assert [project] = Projects.list_projects()
      assert Projects.env_var(project.id, "GITHUB_TOKEN")
    end

    test "no token means no env entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#setup-project-form",
        project: %{
          name: "Acme Site",
          repo_name: "acme-site",
          git_url: "https://github.com/acme/site.git",
          default_branch: "main",
          access_token: ""
        }
      )
      |> render_submit()

      assert [project] = Projects.list_projects()
      assert Projects.env_vars(project.id) == []
    end
  end

  describe "agent step" do
    setup [:with_admin, :with_provider]

    test "creates an org-scoped agent", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> element("#setup-skip-project") |> render_click()

      view
      |> form("#setup-agent-form",
        agent: %{
          name: "Judy",
          work_type: "code",
          roles: "execute,review",
          driver: "acp",
          harness: "claude_code",
          provider_id: provider.id,
          model_variant: "claude-sonnet-5",
          system_prompt: "Be pragmatic."
        }
      )
      |> render_submit()

      assert Agents.any_agents?()
      assert has_element?(view, "#setup-finish")
    end

    test "an llm_api agent needs no harness", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> element("#setup-skip-project") |> render_click()

      view
      |> form("#setup-agent-form",
        agent: %{
          name: "Copywriter",
          work_type: "content",
          roles: "review",
          driver: "llm_api",
          provider_id: provider.id
        }
      )
      |> render_submit()

      assert Agents.any_agents?()
    end
  end

  describe "finishing" do
    setup [:with_admin, :with_provider]

    test "skipping everything still finishes and opens the app", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> element("#setup-skip-project") |> render_click()
      view |> element("#setup-skip-agent") |> render_click()

      assert has_element?(view, "#setup-finish")

      view |> element("#setup-finish") |> render_click()

      assert_redirect(view, ~p"/")
      assert Accounts.setup_done?()
    end

    test "a completed instance is redirected away from the wizard", %{conn: conn} do
      {:ok, _organization} = Accounts.complete_setup()

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/setup")
    end
  end

  defp with_admin(%{conn: conn}) do
    conn =
      post(conn, ~p"/setup/admin", %{
        "organization" => %{"name" => "Acme"},
        "user" => %{"email" => "admin@example.com", "password" => @password}
      })

    %{conn: recycle(conn)}
  end

  defp with_provider(_context) do
    {:ok, provider} =
      Agents.create_provider(%{
        name: "Anthropic",
        kind: :anthropic_api,
        config: %{"api_key" => "sk-test"}
      })

    %{provider: provider}
  end
end
