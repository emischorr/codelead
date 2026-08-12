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

# The seeded instance is already marked set up, so it skips the wizard —
# which means the admin needs a real password to log in with.
admin_password = System.get_env("ADMIN_PASSWORD", "codelead-dev-password")

admin =
  case Accounts.get_user_by_email("admin@example.com") do
    nil ->
      {:ok, user} =
        Accounts.register_admin(%{email: "admin@example.com", password: admin_password})

      user

    user ->
      user
  end

IO.puts(
  "Seeded organization ##{organization.id} (#{organization.name}), admin ##{admin.id} (#{admin.email})"
)

IO.puts("Log in with #{admin.email} / #{admin_password} (override with ADMIN_PASSWORD)")

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
  name: "Survey (Repo-aware Planner)",
  scope: :org,
  roles: [:plan],
  work_type: :code,
  driver: :acp,
  harness: :claude_code,
  provider_id: anthropic.id,
  model_variant: "claude-sonnet-5",
  system_prompt:
    "You survey existing codebases to find what a task's spec leaves out. You are read-only: you never write code, branches, or commits. Cite files and be concrete about what is missing."
})

seed_agent.(%{
  name: "Spec Coach",
  scope: :org,
  roles: [:plan],
  work_type: :code,
  driver: :llm_api,
  provider_id: anthropic.id,
  model_variant: "claude-sonnet-5",
  system_prompt:
    "You help a product owner turn a rough task into a clear spec with acceptance criteria. Ask for what is missing rather than inventing it."
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

IO.puts("Seeded providers: Anthropic ##{anthropic.id}, Ollama ##{ollama.id}; 5 agents")

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

  # --- Demo-only fabricated tasks below -----------------------------------
  # These write state directly via Repo so every board column and task
  # state renders in the UI without running real agents. Real workflows
  # never mutate tasks this way.

  alias CodeLead.AgentFeed
  alias CodeLead.Costs
  alias CodeLead.Repo
  alias CodeLead.Reviews.Review

  fabricate = fn attrs, extra ->
    {:ok, task} = Tasks.create_task(project.id, attrs)
    task |> Ecto.Changeset.change(extra) |> Repo.update!()
  end

  # Demo numbers, shaped like what a real ACP run records: most of the
  # tokens are cache reads, and the cost comes from the harness rather
  # than the local rate table.
  fake_run = fn task, agent, tokens, cents, minutes_ago, duration_ms ->
    started = DateTime.add(DateTime.utc_now(:second), -minutes_ago * 60, :second)
    cached_read = div(tokens * 7, 10)
    completion = div(tokens, 10)

    {:ok, _run} =
      Costs.record_run(%{
        task_id: task.id,
        agent_id: agent.id,
        provider_id: agent.provider_id,
        usage: %{
          prompt_tokens: tokens - cached_read - completion,
          completion_tokens: completion,
          cached_read_tokens: cached_read,
          cached_write_tokens: 0,
          reasoning_tokens: 0,
          total_tokens: tokens,
          cost_cents: cents
        },
        status: :ok,
        started_at: started,
        finished_at: DateTime.add(started, div(duration_ms, 1000), :second),
        duration_ms: duration_ms
      })
  end

  # Running column: one task failed mid-run.
  failed =
    fabricate.(
      %{
        title: "Nightly worktree GC job",
        description: "Sweep orphaned worktrees on a nightly cron.",
        work_type: :code,
        agent_id: judy.id
      },
      state: :running,
      run_state: :failed
    )

  {:ok, failed} = Tasks.set_attention(failed, :run_failed, "mix test exited with status 1")
  fake_run.(failed, judy, 122_000, 141, 45, 214_000)
  Tasks.record_step(failed.id, :transition, :human, "human", "moved to Running (queued)")
  Tasks.record_step(failed.id, :run, :agent, judy.name, "run started")

  Tasks.record_step(
    failed.id,
    :transition,
    :system,
    "system",
    "run failed: mix test exited with status 1"
  )

  # Review column: run finished, two reviewer verdicts recorded.
  review =
    fabricate.(
      %{
        title: "Fix worktree cleanup race",
        description: "Serialize release/1 against in-flight agent writes.",
        work_type: :code,
        priority: :high,
        agent_id: judy.id
      },
      state: :review,
      run_state: :idle,
      branch_name: "task/fix-worktree-cleanup-race"
    )

  :ok = Tasks.set_reviewers(review, [auditor.id, judy.id])

  {:ok, review} =
    Tasks.set_attention(review, :review_ready, "2 reviewers finished · 1 pass, 1 concerns")

  fake_run.(review, judy, 412_300, 342, 120, 1_284_000)
  fake_run.(review, auditor, 44_200, 46, 60, 47_500)
  Tasks.record_step(review.id, :transition, :human, "human", "moved to Running (queued)")
  Tasks.record_step(review.id, :run, :agent, judy.name, "run completed · 3 files changed")
  Tasks.record_step(review.id, :transition, :system, "system", "run completed — moved to Review")

  # A transcript for the Agent tab: one message, a tool-call group, a
  # closing message, the result.
  [
    %{kind: :run_started, text: "#{judy.name} started"},
    %{kind: :message, text: "Reading the worktree teardown path before I touch the lock."},
    %{
      kind: :tool_call,
      text: "Read lib/code_lead/git.ex",
      external_id: "tc-1",
      data: %{
        "status" => "completed",
        "tool_kind" => "read",
        "locations" => ["lib/code_lead/git.ex"]
      }
    },
    %{
      kind: :tool_call,
      text: "Read lib/code_lead/workspace.ex",
      external_id: "tc-2",
      data: %{"status" => "completed", "tool_kind" => "read"}
    },
    %{
      kind: :tool_call,
      text: "Write lib/code_lead/workspace.ex",
      external_id: "tc-3",
      data: %{"status" => "completed", "tool_kind" => "edit"}
    },
    %{
      kind: :tool_call,
      text: "mix test test/code_lead/workspace_test.exs",
      external_id: "tc-4",
      data: %{
        "status" => "completed",
        "tool_kind" => "execute",
        "input" => %{
          "command" => "mix test test/code_lead/workspace_test.exs",
          "description" => "Run the workspace tests"
        }
      }
    },
    %{
      kind: :message,
      text: """
      `release/1` now takes the task lock before pruning:

      - the lock is acquired **before** the worktree is removed
      - a stale lock is reclaimed after `@lock_timeout_ms`

      ```elixir
      def release(task_id) do
        with :ok <- Lock.acquire(task_id) do
          prune(task_id)
        end
      end
      ```

      Tests pass.
      """
    },
    %{
      kind: :result,
      data: %{
        "status" => "ok",
        "tokens" => 412_300,
        "cost_cents" => 342,
        "duration_ms" => 1_284_000
      }
    }
  ]
  |> Enum.each(&AgentFeed.record_event(review.id, &1))

  Repo.insert!(%Review{
    task_id: review.id,
    cycle: 1,
    agent_id: auditor.id,
    verdict: :pass,
    findings:
      "No injection risks or secret leakage in the changed files. Lock scoping looks correct."
  })

  Repo.insert!(%Review{
    task_id: review.id,
    cycle: 1,
    agent_id: judy.id,
    verdict: :concerns,
    findings:
      "1. acquire_lock/2 retries swallow the abort reason — log it.\n2. schedule_retry/1 has no backoff cap; a stuck tree retries forever."
  })

  # Done column: approved with a finalizer note.
  now = DateTime.utc_now(:second)

  done =
    fabricate.(
      %{
        title: "Rate-limit provider calls",
        description: "Token-bucket per provider with retry budget.",
        work_type: :code,
        agent_id: judy.id
      },
      state: :done,
      run_state: :idle,
      completed_at: DateTime.add(now, -9 * 3600, :second),
      inserted_at: DateTime.add(now, -34 * 3600, :second)
    )

  fake_run.(done, judy, 301_200, 290, 600, 903_000)
  Tasks.record_step(done.id, :transition, :human, "human", "moved to Running (queued)")
  Tasks.record_step(done.id, :run, :agent, judy.name, "run completed · 5 files changed")
  Tasks.record_step(done.id, :transition, :system, "system", "run completed — moved to Review")

  Tasks.record_step(
    done.id,
    :commit,
    :system,
    "finalizer",
    "pushed codelead/rate-limit · compare on origin"
  )

  Tasks.record_step(done.id, :transition, :human, "human", "approved — Done")

  # A fortnight of finished work. Without a spread of completion dates the
  # dashboard's throughput chart is a single bar on a fresh database, which
  # reads as a broken widget rather than an empty one.
  # {days_ago, title, tokens, cents, duration_ms, lead_hours}
  history = [
    {13, "Add pagination to the user list endpoint", 88_400, 74, 512_000, 30},
    {12, "Fix container cleanup on run timeout", 141_900, 118, 731_000, 8},
    {10, "Stream NDJSON agent output to the task page", 262_500, 231, 1_104_000, 52},
    {9, "Cache provider model lists for a day", 61_300, 49, 288_000, 5},
    {7, "Retry the ACP handshake on cold start", 118_700, 96, 604_000, 20},
    {5, "Collapse duplicate board broadcasts", 74_600, 58, 341_000, 6},
    {4, "Guard settings deletes behind usage checks", 199_800, 174, 918_000, 46},
    {4, "Self-host DM Sans and JetBrains Mono", 47_200, 38, 205_000, 3},
    {2, "Remember the last project in the sidebar", 93_100, 81, 447_000, 11}
  ]

  Enum.each(history, fn {days_ago, title, tokens, cents, duration_ms, lead_hours} ->
    completed_at = DateTime.add(now, -days_ago * 24 * 3600, :second)

    task =
      fabricate.(
        %{title: title, work_type: :code, agent_id: judy.id},
        state: :done,
        run_state: :idle,
        completed_at: completed_at,
        inserted_at: DateTime.add(completed_at, -lead_hours * 3600, :second),
        updated_at: completed_at
      )

    # Start the run just before its completion so the spend series and the
    # throughput series agree on which day the work happened.
    minutes_ago = div(DateTime.diff(now, completed_at), 60) + div(duration_ms, 60_000)
    fake_run.(task, judy, tokens, cents, minutes_ago, duration_ms)
    Tasks.record_step(task.id, :transition, :human, "human", "approved — Done")
  end)

  IO.puts(
    "Seeded demo project ##{project.id}: 2 planning, 1 failed run, 1 review, #{length(history) + 1} done"
  )
end
