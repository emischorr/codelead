# Seeds the organization singleton and an admin user. Idempotent —
# safe to run repeatedly (mix ecto.setup / ecto.reset run it).
#
#     mix run priv/repo/seeds.exs

alias CodeLead.Accounts
alias CodeLead.Agents

{:ok, organization} =
  Accounts.ensure_organization(%{
    name: "CodeLead",
    settings: %{"setup_done" => true}
  })

admin =
  case Accounts.get_user_by_email("admin@example.com") do
    nil ->
      {:ok, user} = Accounts.create_user(%{email: "admin@example.com", role: :admin})
      user

    user ->
      user
  end

IO.puts(
  "Seeded organization ##{organization.id} (#{organization.name}), admin ##{admin.id} (#{admin.email})"
)

# Providers. The Anthropic key comes from the local environment when
# present; a placeholder otherwise (update via Agents.update_provider/2).
anthropic =
  Agents.get_provider_by_name("Anthropic") ||
    (
      {:ok, provider} =
        Agents.create_provider(%{
          name: "Anthropic",
          kind: :anthropic_api,
          config: %{"api_key" => System.get_env("ANTHROPIC_API_KEY", "replace-me")}
        })

      provider
    )

ollama =
  Agents.get_provider_by_name("Ollama") ||
    (
      {:ok, provider} =
        Agents.create_provider(%{
          name: "Ollama",
          kind: :ollama,
          config: %{"endpoint" => System.get_env("OLLAMA_ENDPOINT", "http://localhost:11434")}
        })

      provider
    )

seed_agent = fn attrs ->
  existing =
    CodeLead.Repo.get_by(CodeLead.Agents.Agent, name: attrs.name)

  if existing do
    existing
  else
    {:ok, agent} = Agents.create_agent(attrs)
    agent
  end
end

seed_agent.(%{
  name: "Judy (Frontend Coder)",
  scope: :org,
  roles: [:execute, :review],
  work_type: :code,
  driver: :acp,
  harness: :claude_code,
  provider_id: anthropic.id,
  model_variant: "claude-sonnet-5",
  system_prompt:
    "You are Judy, a pragmatic senior frontend engineer. Follow the project's conventions, keep diffs small, and explain tradeoffs briefly."
})

seed_agent.(%{
  name: "Security Auditor",
  scope: :org,
  roles: [:review],
  work_type: :code,
  driver: :llm_api,
  provider_id: anthropic.id,
  model_variant: "claude-sonnet-5",
  system_prompt:
    "You are a security reviewer. Look for injection risks, secrets in code, authz gaps, and unsafe defaults. Be specific and cite files/lines."
})

seed_agent.(%{
  name: "Copywriter",
  scope: :org,
  roles: [:execute, :review],
  work_type: :content,
  driver: :llm_api,
  provider_id: ollama.id,
  model_variant: "llama3.1",
  system_prompt:
    "You write clear, concise product copy in the project's voice. Prefer short sentences and concrete benefits."
})

IO.puts("Seeded providers: Anthropic ##{anthropic.id}, Ollama ##{ollama.id}; 3 agents")

# Demo project with tasks across the board (skipped if it exists).
alias CodeLead.Projects
alias CodeLead.Tasks

unless Enum.any?(Projects.list_projects(), &(&1.name == "Demo Product")) do
  {:ok, project} = Projects.create_project(%{name: "Demo Product"})

  # A local git origin so the whole repo flow (worktree → commit →
  # push → compare) works offline. Lives under the workspace root.
  workspace = Application.fetch_env!(:code_lead, :workspace_root)
  origin_path = Path.join([workspace, "demo", "demo-site.git"])

  unless File.dir?(origin_path) do
    seed_path = Path.join([workspace, "demo", "demo-site-seed"])
    File.mkdir_p!(origin_path)
    identity = ["-c", "user.name=CodeLead", "-c", "user.email=codelead@localhost"]
    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", origin_path])
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", seed_path])
    File.write!(Path.join(seed_path, "README.md"), "# Demo Site\n\nSeeded by CodeLead.\n")
    File.write!(Path.join(seed_path, "index.html"), "<html><body><h1>Demo</h1></body></html>\n")
    {_, 0} = System.cmd("git", ["-C", seed_path, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", seed_path] ++ identity ++ ["commit", "-m", "initial"])
    {_, 0} = System.cmd("git", ["-C", seed_path, "push", "file://#{origin_path}", "main:main"])
    File.rm_rf!(seed_path)
  end

  {:ok, _repository} =
    Projects.link_repository(project.id, %{
      name: "demo-site",
      git_url: "file://#{origin_path}",
      default_branch: "main"
    })

  judy = CodeLead.Repo.get_by!(CodeLead.Agents.Agent, name: "Judy (Frontend Coder)")
  auditor = CodeLead.Repo.get_by!(CodeLead.Agents.Agent, name: "Security Auditor")
  copywriter = CodeLead.Repo.get_by!(CodeLead.Agents.Agent, name: "Copywriter")

  :ok = CodeLead.Agents.set_default_reviewers(project.id, :code, [auditor.id])

  {:ok, planning} =
    Tasks.create_task(project.id, %{
      title: "Add pricing page",
      description: "Three tiers, monthly/yearly toggle.",
      work_type: :code,
      priority: :high,
      agent_id: judy.id
    })

  :ok = Tasks.set_reviewers(planning, [auditor.id])

  {:ok, _content_task} =
    Tasks.create_task(project.id, %{
      title: "Landing page hero copy",
      description: "Punchy headline + subline for the launch.",
      work_type: :content,
      agent_id: copywriter.id
    })

  IO.puts("Seeded demo project ##{project.id} with 2 planning tasks")
end
