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
        Accounts.register_admin(%{
          username: "admin",
          email: "admin@example.com",
          password: admin_password
        })

      user

    user ->
      user
  end

IO.puts(
  "Seeded organization ##{organization.id} (#{organization.name}), admin ##{admin.id} (#{admin.username})"
)

IO.puts("Log in with #{admin.username} / #{admin_password} (override with ADMIN_PASSWORD)")

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

seed_agent.(%{
  name: "Style Editor",
  scope: :org,
  roles: [:review],
  work_type: :content,
  driver: :llm_api,
  provider_id: anthropic.id,
  model_variant: "claude-haiku-4-5-20251001",
  system_prompt:
    "You review copy for tone, clarity, and consistency with the style guide. Be direct and quote the lines you would change."
})

IO.puts("Seeded providers: Anthropic ##{anthropic.id}, Ollama ##{ollama.id}; 6 agents")

# Demo project with tasks across the board (skipped if it exists).
alias CodeLead.Projects
alias CodeLead.Tasks

admin_scope = CodeLead.Accounts.Scope.for_user(admin)

unless Enum.any?(Projects.list_projects(), &(&1.name == "Demo Product")) do
  {:ok, project} = Projects.create_project(admin_scope, %{name: "Demo Product"})

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
  alias CodeLead.Findings.Finding
  alias CodeLead.Planning.PlanningMessage
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

  {:ok, failed} =
    Tasks.set_attention(failed, :run_failed, "mix test exited with status 1", :executor)

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
    Tasks.set_attention(
      review,
      :review_ready,
      "2 reviewers finished · 1 pass, 1 concerns",
      :advisory
    )

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

  # Reviews in the shared two-part contract: narrative + fenced JSON
  # payload carrying the verdict, itemized as `phase: :review` findings.
  auditor_step =
    Tasks.record_step(
      review.id,
      :review,
      :agent,
      auditor.name,
      "review cycle 1: pass",
      Integer.to_string(auditor.id)
    )

  Repo.insert!(%Review{
    task_id: review.id,
    task_step_id: auditor_step.id,
    cycle: 1,
    agent_id: auditor.id,
    verdict: :pass,
    findings: """
    No injection risks or secret leakage in the changed files. Lock
    scoping looks correct.

    ```json
    {"verdict": "pass", "findings": [], "prior": []}
    ```
    """
  })

  judy_step =
    Tasks.record_step(
      review.id,
      :review,
      :agent,
      judy.name,
      "review cycle 1: concerns",
      Integer.to_string(judy.id)
    )

  Repo.insert!(%Review{
    task_id: review.id,
    task_step_id: judy_step.id,
    cycle: 1,
    agent_id: judy.id,
    verdict: :concerns,
    findings: """
    The lock scoping is right, but two details of the retry path worry
    me — see the findings.

    ```json
    {"verdict": "concerns", "findings": [{"title": "Cap the retry backoff in schedule_retry/1", "severity": "high", "body": "A stuck tree retries forever; add a max attempts or ceiling.", "paths": ["lib/code_lead/workspace.ex"]}, {"title": "Log the abort reason in acquire_lock/2 retries", "severity": "low", "body": "Retries swallow the abort reason, which makes stuck locks hard to debug.", "paths": ["lib/code_lead/workspace.ex:88"]}], "prior": []}
    ```
    """
  })

  Repo.insert!(%Finding{
    task_id: review.id,
    phase: :review,
    agent_id: judy.id,
    first_seen_step_id: judy_step.id,
    last_seen_step_id: judy_step.id,
    severity: :high,
    title: "Cap the retry backoff in schedule_retry/1",
    body: "A stuck tree retries forever; add a max attempts or ceiling.",
    paths: ["lib/code_lead/workspace.ex"],
    observed: :open
  })

  Repo.insert!(%Finding{
    task_id: review.id,
    phase: :review,
    agent_id: judy.id,
    first_seen_step_id: judy_step.id,
    last_seen_step_id: judy_step.id,
    severity: :low,
    title: "Log the abort reason in acquire_lock/2 retries",
    body: "Retries swallow the abort reason, which makes stuck locks hard to debug.",
    paths: ["lib/code_lead/workspace.ex:88"],
    observed: :open
  })

  # Planning column: a task whose repo survey already reported findings —
  # one addressed (feeds the Decisions block), one dismissed, one open.
  surveyor = CodeLead.Repo.get_by!(CodeLead.Agents.Agent, name: "Survey (Repo-aware Planner)")

  {:ok, surveyed} =
    Tasks.create_task(project.id, %{
      title: "CSV export for cost rollups",
      description: "Let the owner download the monthly cost rollup as CSV.",
      work_type: :code,
      agent_id: judy.id
    })

  survey_step = Tasks.record_step(surveyed.id, :plan, :agent, surveyor.name, "repo survey: ok")

  survey_report = """
  Cost rollups live in `lib/code_lead/costs.ex` (nightly Oban job, one
  row per day and provider). There is no export path and no controller
  that streams a download yet; the dashboard reads the rollups through
  `Costs.project_spend_month/1`.

  ```json
  {"findings": [{"title": "Decide the CSV column set and date range", "severity": "high", "body": "The rollup table carries more than the dashboard shows; the spec has to pick columns.", "paths": ["lib/code_lead/costs.ex"]}, {"title": "Choose streaming vs. one-shot download", "severity": "medium", "body": "A year of rollups is small; a plain controller response is probably enough.", "paths": []}, {"title": "Filename convention for the download", "severity": "low", "body": "Pick something stable for spreadsheets, e.g. costs-<project>-<month>.csv.", "paths": []}], "prior": []}
  ```
  """

  Repo.insert!(%PlanningMessage{
    task_id: surveyed.id,
    agent_id: surveyor.id,
    role: :assistant,
    kind: :survey,
    content: survey_report
  })

  survey_finding = fn severity, title, body, paths ->
    Repo.insert!(%Finding{
      task_id: surveyed.id,
      phase: :planning,
      agent_id: surveyor.id,
      first_seen_step_id: survey_step.id,
      last_seen_step_id: survey_step.id,
      severity: severity,
      title: title,
      body: body,
      paths: paths,
      observed: :open
    })
  end

  columns_finding =
    survey_finding.(
      :high,
      "Decide the CSV column set and date range",
      "The rollup table carries more than the dashboard shows; the spec has to pick columns.",
      ["lib/code_lead/costs.ex"]
    )

  streaming_finding =
    survey_finding.(
      :medium,
      "Choose streaming vs. one-shot download",
      "A year of rollups is small; a plain controller response is probably enough.",
      []
    )

  _open_finding =
    survey_finding.(
      :low,
      "Filename convention for the download",
      "Pick something stable for spreadsheets, e.g. costs-<project>-<month>.csv.",
      []
    )

  now = DateTime.utc_now(:second)

  columns_finding
  |> Ecto.Changeset.change(
    resolution: :addressed,
    resolution_note: "Day, provider, tokens, cost. Current month only for now.",
    resolved_by_id: admin.id,
    resolved_at: now
  )
  |> Repo.update!()

  streaming_finding
  |> Ecto.Changeset.change(
    resolution: :dismissed,
    resolution_note: "One-shot is fine at this size.",
    resolved_by_id: admin.id,
    resolved_at: now
  )
  |> Repo.update!()

  # Running column: a task admitted but still waiting on the scheduler.
  queued =
    fabricate.(
      %{
        title: "Board column virtualization",
        description: "Windowed rendering once a column passes ~200 cards.",
        work_type: :code,
        agent_id: judy.id
      },
      state: :running,
      run_state: :queued
    )

  Tasks.record_step(queued.id, :transition, :human, "human", "moved to Running (queued)")

  # Done column: approved with a finalizer note.

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
    "Seeded demo project ##{project.id}: 3 planning (1 with survey findings), " <>
      "1 failed run, 1 queued, 1 review (structured findings), #{length(history) + 1} done"
  )
end

# Second project: content work without a repository — planning with and
# without findings, and a review cycle that demos the degradation paths
# (a verdict-only reply and a failed reviewer). Skipped if it exists.
unless Enum.any?(Projects.list_projects(), &(&1.name == "Marketing Site")) do
  alias CodeLead.Costs
  alias CodeLead.Repo
  alias CodeLead.Reviews.Review

  {:ok, marketing} = Projects.create_project(admin_scope, %{name: "Marketing Site"})

  copywriter = Repo.get_by!(CodeLead.Agents.Agent, name: "Copywriter")
  style = Repo.get_by!(CodeLead.Agents.Agent, name: "Style Editor")

  :ok = CodeLead.Agents.set_default_reviewers(marketing.id, :content, [style.id])

  fabricate = fn attrs, extra ->
    {:ok, task} = Tasks.create_task(marketing.id, attrs)
    task |> Ecto.Changeset.change(extra) |> Repo.update!()
  end

  fake_run = fn task, agent, tokens, cents, minutes_ago, duration_ms ->
    started = DateTime.add(DateTime.utc_now(:second), -minutes_ago * 60, :second)

    {:ok, _run} =
      Costs.record_run(%{
        task_id: task.id,
        agent_id: agent.id,
        provider_id: agent.provider_id,
        usage: %{
          prompt_tokens: div(tokens * 2, 10),
          completion_tokens: div(tokens, 10),
          cached_read_tokens: tokens - div(tokens * 2, 10) - div(tokens, 10),
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

  # Planning column: no findings yet on either.
  {:ok, _launch} =
    Tasks.create_task(marketing.id, %{
      title: "Q4 launch announcement",
      description: "Blog post plus the social snippets, in the launch voice.",
      work_type: :content,
      priority: :high,
      agent_id: copywriter.id
    })

  {:ok, _faq} =
    Tasks.create_task(marketing.id, %{
      title: "Pricing FAQ refresh",
      description: "Fold in the new tier names and the yearly discount.",
      work_type: :content,
      agent_id: copywriter.id
    })

  # Review column: one reviewer replied with the bare verdict JSON (the
  # UI shows "No findings recorded." with the raw report behind the
  # toggle) and one failed outright (verdict-less row, raw fallback).
  emails =
    fabricate.(
      %{
        title: "Onboarding email rewrite",
        description: "Three-step drip; shorter, one CTA per mail.",
        work_type: :content,
        agent_id: copywriter.id
      },
      state: :review,
      run_state: :idle
    )

  :ok = Tasks.set_reviewers(emails, [copywriter.id, style.id])

  {:ok, emails} =
    Tasks.set_attention(
      emails,
      :review_ready,
      "2 reviewers finished · 1 concerns, 1 failed",
      :advisory
    )

  fake_run.(emails, copywriter, 38_400, 0, 90, 41_000)
  Tasks.record_step(emails.id, :transition, :human, "human", "moved to Running (queued)")
  Tasks.record_step(emails.id, :run, :agent, copywriter.name, "run completed")
  Tasks.record_step(emails.id, :transition, :system, "system", "run completed — moved to Review")

  style_step =
    Tasks.record_step(
      emails.id,
      :review,
      :agent,
      style.name,
      "review cycle 1: concerns",
      Integer.to_string(style.id)
    )

  Repo.insert!(%Review{
    task_id: emails.id,
    task_step_id: style_step.id,
    cycle: 1,
    agent_id: style.id,
    verdict: :concerns,
    findings: ~s({"verdict": "concerns"})
  })

  copy_step =
    Tasks.record_step(
      emails.id,
      :review,
      :agent,
      copywriter.name,
      "review cycle 1: no verdict",
      Integer.to_string(copywriter.id)
    )

  Repo.insert!(%Review{
    task_id: emails.id,
    task_step_id: copy_step.id,
    cycle: 1,
    agent_id: copywriter.id,
    verdict: nil,
    findings: "review failed: reviewer timed out after 15 minutes"
  })

  # Done column.
  now = DateTime.utc_now(:second)

  renamed =
    fabricate.(
      %{
        title: "Rename tiers across the site",
        description: "Starter/Team/Scale everywhere the old names appear.",
        work_type: :content,
        agent_id: copywriter.id
      },
      state: :done,
      run_state: :idle,
      completed_at: DateTime.add(now, -3 * 24 * 3600, :second),
      inserted_at: DateTime.add(now, -4 * 24 * 3600, :second)
    )

  fake_run.(renamed, copywriter, 21_700, 0, 3 * 24 * 60, 18_000)
  Tasks.record_step(renamed.id, :transition, :human, "human", "approved — Done")

  IO.puts(
    "Seeded marketing project ##{marketing.id}: 2 planning, 1 review (degradation demos), 1 done"
  )
end
