# Console API walkthrough (last updated: 2026-08-10)

The MVP has no web UI yet — the human interface is the IEx console.
Everything below uses the exact context functions the future LiveView
will call. Prerequisites: `docker compose up -d`, `mix ecto.reset`
(seeds the org, admin, providers, agents, and a Demo Product with a
local `demo-site` git origin), then `iex -S mix`.

```elixir
alias CodeLead.{Accounts, Agents, Costs, Planning, Projects, Reviews, Runtime, Tasks}

project = Projects.list_projects() |> hd()
[repo] = Projects.list_repositories(project.id)

# Secrets for the executor environment (encrypted at rest):
Projects.put_env(project.id, "API_KEY", "s3cret")
```

## 1. Plan a task

```elixir
{:ok, task} =
  Tasks.create_task(project.id, %{
    title: "Add a pricing page",
    description: "Three tiers, monthly/yearly toggle.",
    work_type: :code                    # target defaults to :repo, first linked repo
  })

# Optional AI planning chat (uses an llm_api agent, read-only repo context):
[judy, auditor, _copy] = for n <- ["Judy (Frontend Coder)", "Security Auditor", "Copywriter"],
                             do: CodeLead.Repo.get_by!(CodeLead.Agents.Agent, name: n)
Planning.chat(task.id, auditor.id)      # type into the REPL; `exit` to leave
{:ok, task} = Tasks.update_task(task, %{spec: "…crystallized acceptance criteria…"})

{:ok, task} = Tasks.set_executor(task, judy.id)
:ok         = Tasks.set_reviewers(task, [auditor.id])
```

## 2. Run it

```elixir
Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")
Phoenix.PubSub.subscribe(CodeLead.PubSub, "project:#{project.id}")

{:ok, task} = Runtime.start_task(task)   # queued → dispatched → executing
flush()                                  # live event stream

# If the agent asks for an out-of-sandbox permission (attention on card):
Runtime.answer_permission(task, request_id, true)

# Abort (keeps the worktree for inspection):
Runtime.cancel_task(Tasks.get_task!(task.id))
# After a failure (attention :run_failed):
Runtime.retry_task(Tasks.get_task!(task.id))
```

Note: ACP runs need the harness CLI on PATH (`claude-code-acp` — see
the `:harnesses` config) and provider credentials on the provider row.

## 3. Review

Reviewers ran automatically on Review entry (advisory only):

```elixir
task = Tasks.get_task!(task.id)          # state: :review, attention: :review_ready
Reviews.list_reviews(task.id)            # verdicts + findings per reviewer/cycle
CodeLead.Git.diff(task.worktree_path, repo.default_branch) |> elem(1) |> IO.puts()

# Decide:
{:ok, task} = Runtime.request_changes(task, "Add tests for the toggle")  # same branch/session
{:ok, task} = Runtime.send_back_to_planning(task)                        # discard everything
{:ok, task, outcome} = Runtime.approve(task)                             # commit, push, PR/compare
```

## 4. Costs & board

```elixir
Tasks.board(project.id)                  # kanban columns
Tasks.attention_tasks(project.id)        # attention counter
Tasks.steps(task.id)                     # audit trail
Costs.task_spend(task.id)                # executor + reviewer runs
Costs.project_spend(project.id)
Projects.update_project(project, %{budget_limit_cents: 500})  # budget gate

{:ok, task} = Tasks.archive(task)        # hide from board; reversible
```
