# CodeLead — Technical / Architecture Specification (MVP)

> Companion to the Product Spec. Defines the data model, state machine, and abstractions to build toward. Every extension point is a behaviour with **one** MVP implementation and an explicit later impl.

---

## 1. Stack

- **Backend:** Elixir, Phoenix LiveView.
- **Data:** PostgreSQL via Ecto.
- **Realtime:** Phoenix.PubSub — agent output and board updates fan out to LiveViews.
- **Background jobs / rollups:** Oban.
- **Agent transport:** ACP (Agent Client Protocol) — JSON-RPC 2.0 over stdio, bridged via Erlang Ports. Evaluate the **ACPex** Elixir library vs. a thin hand-rolled JSON-RPC subset.
- **Secrets:** Cloak.Ecto encrypted fields, keyed by an instance `ENCRYPTION_KEY`.
- **Packaging:** single Docker image (bundling the agent CLIs), docker socket mountable, Postgres, one persistent data volume.

---

## 2. Guiding principles

1. **Human gates at workflow transitions.** No state advances a task past a human without explicit action. The one exception is Running→Review on success, which is a *completion signal*, not a decision.
2. **CodeLead is the ACP client** and owns the workspace, filesystem, terminal, and permission decisions; the agent is a subprocess it drives.
3. **Derive task state from protocol events, not agent self-report.**
4. **Prefer existing OTP patterns** (GenServer, PubSub, Ports, Oban) over new abstractions.

---

## 3. Domain model (Ecto schemas)

Key fields only. `enc` = encrypted at rest. `seam` = present for a future feature, unused in MVP logic.

- **organization** — singleton for the instance: `name`, `settings` *(jsonb; includes `setup_done`, `max_concurrent_runs`)*, `budget_limit_cents` (nullable), `budget_limit_tokens` (nullable).
- **users** — `email`, `hashed_password`, `role` (`:admin` | `:member`), `locale`, `settings` *(jsonb: theme, UI preferences)*.
- **projects** — `org_id`, `name`, `settings`, `budget_limit_cents` (nullable), `budget_limit_tokens` (nullable).
- **repositories** — `project_id`, `name`, `git_url`, `default_branch`, `base_clone_path`.
- **project_envs** — `project_id`, `key`, `value` *(enc)*. Injected as env vars at executor spawn.
- **project_default_reviewers** — `project_id`, `work_type`, `agent_id`. Pre-fills a new task's reviewer set for that work type (editable per task).
- **providers** — `name`, `kind` (`:anthropic_subscription` | `:anthropic_api` | `:openai` | `:ollama` | …), `config` *(enc: tokens/keys/endpoint)*. Instance-scoped.
- **agents** — `name` (persona), `scope` (`:org` | `:project`), `project_id` (nullable), `roles` (array of `:execute` | `:review`), `work_type` (`:code`|`:design`|`:content`|`:file`), `driver` (`:acp` | `:llm_api`), `harness` (`:claude_code` | `:codex` | `nil`), `provider_id`, `model_variant`, `system_prompt`, `memory` *(jsonb, seam)*.
- **tasks** — `project_id`, `title`, `description`, `spec` (refined acceptance criteria), `work_type`, `target` (`:repo` | `:folder`), `priority`, `state` (`:planning`|`:running`|`:review`|`:done`|`:cancelled`), `run_state` (`:idle`|`:queued`|`:dispatched`|`:executing`|`:failed`), `ready_flag` (bool), `agent_id`, `repository_id` (nullable; required when `target = :repo`), `worktree_path` (nullable), `branch_name` (nullable), `acp_session_id` (nullable), `attention` (embedded: `type`, `detail`, `at`), `assignee_id` (nullable), `archived_at` (nullable — orthogonal to `state`).
- **task_steps** — audit trail: `task_id`, `executor_type` (`:agent`|`:system`|`:human`), `executor_name`, `executor_ref` (nullable), `kind` (`:run`|`:review`|`:transition`|`:commit`|…), `summary`, `inserted_at`. **Denormalized** so agent deletion is graceful.
- **task_reviewers** — `task_id`, `agent_id`. The reviewer set chosen for the task (each `agent_id` has `:review` in `roles` and matches the task's `work_type`).
- **reviews** — one row per reviewer per review cycle: `task_id`, `agent_id`, `task_step_id`, `cycle` (int), `verdict` (`:pass`|`:concerns`|`:block`, **advisory**), `findings` (jsonb/text), `inserted_at`.
- **agent_runs** — per-execution cost/usage: `task_id`, `task_step_id`, `agent_id`, `provider_id`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `cost_cents`, `status`, `started_at`, `finished_at`. **Prunable** (~14-day TTL).
- **daily_metrics** — permanent rollup: `project_id`, `date`, `total_tokens`, `cost_cents`, `run_count`.
- **planning_messages** — `task_id`, `role`, `content`. The planning-assistant chat.
- **task_comments** *(optional)* — `task_id`, `user_id`, `body`.

---

## 4. Workflow state machine

`state` is the Kanban column; `run_state` tracks execution within Running.

| From | To | Trigger | Actor | Side effects |
|---|---|---|---|---|
| planning | running | move card | human | enqueue (`run_state := :queued`); scheduler admits/dispatches |
| running | running | dispatch | scheduler + executor | provision context by **target** (`:repo` → worktree+branch / `:folder` → task folder), start agent via driver, persist `acp_session_id`; `run_state := :executing` |
| running | review | agent completes | system | `run_state := :idle`; **fan out one review run per selected reviewer** (parallel, read-only on the worktree) — each writes a `reviews` row + `agent_run` + `task_step`; `attention := :review_ready` when the cycle completes |
| running | planning | cancel | human | terminate agent process, **keep** worktree, `run_state := :idle` |
| running | running | failure | system | `run_state := :failed`, `attention := :run_failed`; **no column change** — human picks retry (re-dispatch) or abort (→ planning) |
| review | done | approve | human | system executor, by **target**: `:repo` → commit remainder, push branch, optional MR/PR (GitHub/GitLab) or compare link; `:folder` → finalize downloadable artifact, optional commit-to-path |
| review | running | request changes | human | **keep** worktree/branch/`acp_session_id`; feedback becomes next prompt; new run (new `task_step`); `run_state := :queued` |
| review | planning | send back to planning | human | **discard** worktree, **delete** feature branch, **clear** `acp_session_id`; human reworks spec |

**Rework distinction (important):** *request changes* preserves the session and accumulates commits on the same branch; *send back to planning* is a clean reset — the prior work was built on a spec now being rewritten, so its context is dropped rather than carried forward.

**Review cycles:** each entry into Review runs a fresh cycle over the task's current reviewer set, incrementing `reviews.cycle`. Prior cycles are retained for audit. Reviews are read-only and run concurrently; multiple reviewers on the same worktree is safe.

**Archive:** setting `archived_at` on a Done (or Cancelled) task excludes it from board/list queries (`where archived_at is nil`) without changing its `state`. Not a workflow transition; reversible by clearing the field. MVP exposes the action on Done only.

**Delete:** a task with no pushed artifacts (`:planning` or `:cancelled`) may be hard-deleted (cascade its planning messages, comments, task_steps). Distinct from archive, which retains a finished task. This is how a split umbrella task is discarded.

---

## 5. Abstractions (behaviours)

### 5.1 Agent driver — `CodeLead.AgentDriver`

Callbacks: `start_run(task, agent, context, prompt)`, `send_message(handle, msg)`, `cancel(handle)`, plus a **normalized event stream** (message chunk, tool call, permission request, question, result-with-usage).

- **`Acp` (MVP):** launches the harness (`claude_code` / `codex`) as an ACP agent subprocess **inside the execution context**; CodeLead is the ACP client; stdio bridged over an Erlang Port; JSON-RPC parsed (ACPex or thin subset). Owns fs/terminal/permission callbacks.
- **`LlmApi` (MVP):** a single completion call to the provider (Ollama/OpenAI/Anthropic API). Used for review, short content, and later the walkthrough. No worktree unless it writes files.

The driver is **independent of the executor** — the ACP subprocess is the same whether local or containerized.

### 5.2 Executor — `CodeLead.Executor`

Callbacks: `provision(task) -> context`, `spawn(context, command) -> process`, `teardown(context, opts)`.

- **`LocalSubprocess` (MVP):** worktree / task-folder on the mounted volume; agent CLI (bundled in image) run as a subprocess; project env injected.
- **`DockerContainer` (later):** wraps the **same** ACP subprocess in a sibling container via the docker socket (isolation, resource caps). User-selectable per agent/task.

### 5.3 Scheduler / Queue — `CodeLead.Scheduler`

Callbacks: `admit?(task) -> :ok | {:hold, reason}`, `dispatch(task)`. **Bound to the task's provider connection**, not global.

- **`PassThrough` (MVP):** `admit?` returns `:ok` unless a **budget limit** is exceeded (limit check lives here); dispatch immediately.
- **`Windowed` (later):** for subscription token windows — hold until reset, then auto-dispatch.

`queued` is a **sub-state shown in the Running column** with a badge, not a new column. Cross-project ordering / priority is iteration two.

**Executor guard:** planning→running is blocked unless the task has an `agent_id` (an executor whose `roles` include `:execute` and whose `work_type` matches). If no eligible agent exists, the UI routes the user to create one rather than dead-ending.

### 5.4 Reviewers

Reviewers are ordinary **agents** with `:review` in `roles`, matched to the task's `work_type`, selected per task (pre-filled from `project_default_reviewers`). They are not a separate abstraction — a reviewer run is just an `AgentDriver` run in a read-only posture.

- On Running→Review, **fan out one run per selected reviewer**, concurrently. Each writes a `reviews` row (advisory `verdict` + `findings`) plus its own `agent_run` and `task_step`.
- A reviewer may be `llm_api` (a quick focused pass — security, tone, SEO) or `acp` (repo-aware, read-only on the worktree — architecture, cross-file consistency).
- Reviews are **advisory only**: no verdict gates the transition. The human reads all findings and makes the Approve / Request-changes / Send-back decision.
- Review runs are cost-tracked like any run but are **not** budget-held in MVP (they run immediately on entry); budget enforcement primarily gates executor dispatch.

---

## 6. ACP integration

- **1:1 by design** — one client ↔ one agent ↔ one session. Multi-user live viewing is handled *above* ACP: the server is the single ACP client; PubSub fans events to all LiveView subscribers.
- **Transport:** JSON-RPC over stdio. MVP launches the agent as a local subprocess; the container executor later attaches over `docker exec -i` — the **same** Port-based stdio bridge either way.
- **Client-provided capabilities:** CodeLead exposes `fs` (read/write) and `terminal` primitives scoped to the task's worktree/folder, and is the **permission gatekeeper**.
- **Permission policy:** inside the isolated worktree/container, **auto-grant** fs/terminal permission requests (no per-tool-call nagging). The human gate is at the **workflow** level. Escalations that leave the sandbox or are destructive are surfaced as attention items for human approval.
- **Sessions:** persist `acp_session_id` per task. On *request changes*, resume the same session to preserve context; on *send back to planning*, drop it. Verify ACPex/ACP session load-resume support when wiring.
- **MCP:** `session/new` can declare MCP servers, so per-agent MCP tooling wires up in the same handshake (future).
- **Agent modes** (plan/ask): deferred; expose as a per-agent/per-task `mode` once the standardized ACP schema modes are confirmed.
- The normalized event stream feeds: **live UI** (PubSub), **attention** (questions/permissions), **audit** (task_steps), and **usage** (agent_runs from the result/usage message).

---

## 7. Git plumbing

- Applies to **`:repo`-target tasks of any work type** (code, and content/design/file that edit a linked repo). `:folder`-target tasks use the task folder and skip the branch/push flow.
- Repos linked by URL; CodeLead keeps **one managed base clone per repository** on the persistent volume.
- Per `:repo` task: a **git worktree** off the base clone on an auto-created feature branch (e.g. `codelead/task-<id>-<slug>`).
- Diffs computed against the branch base. The Review/Artifact tab renders per work type: `code` → diff; `content`/`design` → rendered preview of changed files **with diff available**. Preview renders files directly and does **not** run the project's build pipeline.
- Multi-run accumulates commits on the same branch.
- **Done:** commit remaining changes, push the branch; if the remote is GitHub or GitLab, create an MR/PR via API (token from provider/secret) or show a compare URL. **No auto-merge to main.**
- **Send back to planning:** remove the worktree and delete the feature branch.
- **Retention:** on Done/archive, a coding **worktree may be pruned** (the branch lives on the remote); non-coding **task folders are retained**. Task content (`task_steps`, `reviews`, spec, description) is retained regardless of `agent_runs` pruning, so archived tasks stay searchable/consultable later.

Auth stays on the host/volume; credentials are not baked into the agent image beyond what the executor injects.

---

## 8. Secrets

- **Single** encrypted-at-rest mechanism (Cloak.Ecto), instance `ENCRYPTION_KEY` from env.
- Two consumers: **provider credentials** and the **project env store**.
- Project env injected as environment variables into the executor at spawn (tests, build tooling). Never logged; never written to `task_steps`.

---

## 9. Cost / token tracking

- **Source:** the ACP result/usage message per run (prompt/completion/total tokens, cost); `llm_api` runs report usage from the provider response.
- **Persist** per run in `agent_runs` (prunable). Roll up nightly (Oban) into `daily_metrics` per project per day.
- **Per-task cost** = sum of its `agent_runs` (executor runs **and** each reviewer run — N reviewers multiply per-cycle review cost).
- **Budgets:** organization and project carry optional token/cost limits; the scheduler's `admit?` enforces them (over-limit → `{:hold, :budget}`, task stays queued with a badge).
- MVP surfaces minimal display (per-task total, current budget usage); dashboards/graphs are iteration two on the same tables.

---

## 10. Realtime & processes

- **One GenServer per active task run** supervises the driver/port, normalizes events, updates the task, and broadcasts via a per-task/per-project PubSub topic.
- LiveViews subscribe to board and task topics; **attention is a task field** (no per-user fan-out).
- A **max-concurrent-running cap** (config) protects small servers; excess stays queued.

---

## 11. UI surfaces & data sources

Confirms every UI surface maps to model data. Board/list queries filter `archived_at is nil`.

| Surface | Data sources |
|---|---|
| Board / List | `tasks` (project-scoped, non-archived) + `attention` field + executor/reviewer `agents` |
| Task tab | `tasks` fields, `spec`, `task_reviewers` + `agents`, `planning_messages`, `task_comments`, `repositories` |
| Review / Artifact tab | live worktree diff or task-folder artifact (PubSub) + `reviews` (current `cycle`) |
| Agent tab | executor normalized event stream (PubSub) + `attention` (questions/permissions) + `task_steps` |
| Developer tab | executor terminal session into the task's execution context |
| Settings | `users`, `providers`, `organization` |
| Profile | `users.locale`, `users.settings` |
| Projects | `projects`, `repositories`, `project_envs`, `project_default_reviewers`, budgets |
| Agents | `agents`, `providers` |

The task view auto-selects the tab matching `tasks.state`; Agent/Review/Developer tabs are inert until an execution context exists.

---

## 12. Deployment

- Single Docker image bundling the app + agent CLIs (Claude Code, Codex).
- Mounts: Postgres (external or sibling), one **persistent volume** (base clones, worktrees, task folders), **docker socket** (for the later container executor — harmless if unused in MVP).
- Env: `DATABASE_URL`, `ENCRYPTION_KEY`, `SECRET_KEY_BASE`, optional `MAX_CONCURRENT_RUNS`.
- First run: self-signup creates the admin; wizard guides project → repo → provider → agent.

---

## 13. Extension seams (summary)

| Future feature | Seam already present in MVP |
|---|---|
| Subscription-window queuing | `Scheduler` behaviour (`Windowed` impl) + provider binding + `queued` run_state |
| Container / selectable executor | `Executor` behaviour (`DockerContainer` impl) |
| Review walkthrough | `llm_api` driver reading the diff |
| Agent memory | `agents.memory` field + system-prompt composition |
| Cost dashboards | `agent_runs` + `daily_metrics` already populated |
| Planning / agent modes | agent/task `mode` field + ACP session modes |
| Per-agent MCP tooling | `session/new` mcpServers |
| Priorities / cross-project queue | `Scheduler` ordering |
| Planning assistant as a selectable agent | extend `agents.roles` with `:plan` |
| Search across archived tasks | archived `tasks` retained in Postgres + future full-text / vector index |
| Agent access to past tasks | an ACP/MCP tool exposing archived task history (spec, diffs, reviews) |
| Task splitting / sub-tasks / epics | `tasks.parent_id` (nullable) — MVP leaves it null; splitting is manual |
