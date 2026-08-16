# CodeLead — Product Specification (MVP)

> Target-state MVP. Describes *what* CodeLead is and *how it behaves*, not a migration path from the current codebase. The implementing agent derives the delta from the existing code.

---

## 1. Vision

CodeLead is a **self-hosted, human-in-the-loop platform for building digital products with a team of AI agents**. It elevates a single developer into a product owner: one person directs a virtual team of specialist agents while staying close to the work. It is equally usable by semi-technical builders who want to ship digital products without living in a terminal.

Where an AI coding assistant helps a *developer write code*, CodeLead helps a *product owner build a product* — planning, delegating, reviewing, and shipping work across coding and non-coding tasks.

### Product thesis — human gates are the product

Agents plan and execute; **humans own every handoff between states.** Automation that silently bypasses a human decision point is a design failure, not a feature. This is the deliberate difference from more autonomous, developer-centric tools.

### Positioning vs. Kandev

Kandev validates the shape (self-hosted, worktree isolation, review-first Kanban, agent-agnostic, no telemetry) but is broader and developer-centric. CodeLead is narrower and **product-management-centric**: task management is the primary surface; terminal and diff are a progressively disclosed *developer view*, not the default.

---

## 2. Target users

- Solo developers / freelancers acting as their own product owner.
- Small teams and startups building a product together.
- Semi-technical builders with enough literacy to link a repo and review output.

**Not targeted:** large enterprises (heavy RBAC, SSO, and compliance workflows are out of scope).

---

## 3. Core concepts

| Concept | Definition |
|---|---|
| **Organization** | One deployed instance = one organization. Contains users, projects, agents, providers, budgets. |
| **User** | A person with a login. The first user self-signs-up and becomes admin. |
| **Project** | A product workspace. Links one or more repositories. Owns tasks, project-level agents, project env/secrets, and budgets. |
| **Repository** | A git repo linked by URL to a project. |
| **Agent** | A reusable worker persona: work type + driver + provider/model + system prompt (+ future memory). Defined at org or project level. |
| **Provider** | An instance-level connection to a model backend (Anthropic, OpenAI, Ollama, …), configured in the UI. |
| **Task** | A unit of work with a work type, moving through the workflow, producing an artifact. |
| **Attention** | A state on a task signalling it needs a human. |

---

## 4. Roles (MVP)

- **Admin** — first user; manages users, providers, org-level agents, org budgets, instance settings.
- **Member** — creates projects/tasks/agents, runs and reviews work.

Fine-grained permissions are out of scope for MVP.

---

## 5. Work types & target

Two independent axes describe a task:

- **Work type** — `code` / `design` / `content` / `file`. Drives which agents are selectable (executor and reviewers) and the **review renderer**.
- **Target** — **where the work lands and how Done behaves**, independent of work type:
  - `repo` — a git worktree on an auto-created feature branch in a linked repo; Done commits + pushes the branch and then, per the task's **finalize mode**, opens an MR/PR or merges the branch into the default branch. This is the flow for *any* work type that edits a linked repo — including content and design (e.g. landing-page copy, in-repo docs, HTML templates).
  - `folder` — a standalone task folder for artifacts not tied to a repo; Done hands the artifact over as a download, or commits it to a chosen repo path.

| Work type | Selectable agents | Review renderer | Typical target |
|---|---|---|---|
| `code` | code agents (security, architecture reviewers…) | diff | `repo` |
| `design` | design agents | rendered HTML preview (+ diff if `repo`) | either |
| `content` | content agents (clarity, SEO reviewers…) | rendered Markdown/HTML preview (+ diff if `repo`) | either |
| `file` | generic agents | file list / download | either |

`code` defaults to `repo`; `content` / `design` / `file` default to `folder` but can target a repo. For a `repo`-target content/design task the **preview is primary and the diff is available**. Preview limitation (MVP): the renderer displays the changed **files directly** (Markdown → rendered, standalone HTML → rendered) — it does **not** run the project's build pipeline, so for a page behind a static-site build the diff is the reliable view.

Agents declare a work type; **only agents matching the task's work type are selectable** for both executor and reviewer slots. If **no agent matches** a task's work type, the executor picker is empty and the UI routes the user to create one — a task cannot reach Running without an executor.

---

## 6. Workflow (Kanban)

Four columns: **Planning → Running → Review → Done**. There is deliberately no "Ready" column — in AI-driven work the human is the bottleneck, not worker availability, so the board models human↔agent handoffs, not queues.

### Planning — human workbench

- Create the task; set title, description, **work type**, **target** (repo or folder — repo also picks which linked repo), priority.
- **AI planning agent (optional):** pick a `plan`-role agent — filtered to the task's work type, like every other slot — and work with it to refine the task and surface open questions. Its output crystallizes into the task's spec / acceptance criteria; it never edits the task itself. The agent's **driver** decides what it can do:
  - `llm_api` → **spec refinement** from the task text plus a repository file listing. A chat.
  - `acp` → **repo-aware survey**: the agent reads the linked repository read-only at its current default branch and reports requirements gaps, contradictions with the existing code, and unstated assumptions. Invoked on demand — a pull, not a push. It is the reviewer's read-only posture pointed at the codebase instead of a diff, and lands as a turn in the same conversation.
- **Choose the executor agent** that will do the work, and **zero or more reviewer agents** that will critique it — all filtered to the task's work type. The reviewer set is pre-filled from the project's default reviewers for that work type and stays editable per task.
- **"Ready" flag (optional):** a human-only marker for the user's own reference ("what can I kick off?"). It triggers nothing and moves no card.
- Nothing runs automatically here. The human **manually** moves the task to Running when they decide it's ready.

### Running — agent execution

- Moving a task to Running **enqueues** it; a per-provider scheduler **dispatches** it (MVP: immediately). While waiting it shows a **queued badge** in the Running column.
- On dispatch, CodeLead provisions the execution context by **target**: `repo` → a git worktree on an auto-created feature branch; `folder` → a task folder. Then it starts the agent.
- Live output streams to the board and task view.
- On successful completion the task **moves to Review automatically** (a completion signal, not a human decision).
- **Cancel:** a human can abort a running task — the agent process is terminated, the worktree/folder is kept for inspection, and the task returns to Planning.
- **Failure:** on agent error/crash the task stays in Running with an **error attention badge**; the human decides retry vs abort. A task is never silently stuck.

### Review — AI-assisted, human-decided

- On entry, **each selected reviewer runs automatically and in parallel**, read-only, each producing its own **advisory** findings plus an optional recommendation (*pass / concerns / block*). Reviewers can carry different focuses — e.g. a security reviewer and an architecture reviewer on the same code task — and never transition the task. **If no reviewers are selected, Review is human-only** — the artifact is shown with no AI findings.
- The Review surface shows every reviewer's findings together. The human weighs them, inspects the artifact (diff or preview), and decides:
  - **Approve** → Done.
  - **Request changes** → back to Running with the **same agent, worktree, branch, and session**; the feedback becomes the next prompt. Work accumulates (multi-run).
  - **Send back to Planning** → the worktree, branch, and agent session are **discarded** and the task starts fresh; the human reworks the spec.

### Done

Finalization (no agent) follows the task's **target** and its resolved **finalize mode**.

**`repo`** — commit any remainder and **push the feature branch**, then:

| Mode | What Done does |
|---|---|
| *Pull request* (default) | On GitHub/GitLab open an MR/PR, otherwise show a compare link. Nothing is merged; the remote branch stays for the PR to point at. The description comes from the project's editable **PR template** (see §13), defaulting to a built-in one. |
| *Merge* | Merge the branch into the repository's default branch and push it (a merge commit). |
| *Squash* | The same, condensed into a single commit. |

This is identical for a `content`/`design` task targeting a repo (e.g. the landing-page copy) — the mode follows the target, never the work type.

**`folder`** — hand the task folder over as a **downloadable artifact** (mode *Artifact*), or commit it into a chosen repository path on its own branch (mode *Commit to path*). The folder is retained either way. An **empty** folder is refused rather than finalized: the folder is created before the run, so an agent that answered in chat without writing a file leaves one that exists and holds nothing — there is nothing to hand over, and the human should request changes.

**Cleanup.** On success the worktree is pruned in every mode — the work is on the remote, and a stale worktree is only clutter. Merge and squash also **delete the remote feature branch** (it is redundant once merged); pull-request mode keeps it, because the PR is still open. Task folders are always retained.

**Merging is local git, never a forge action.** CodeLead runs `git merge` + `git push` against the default branch, so it works with any remote — self-hosted forges, plain SSH, `file://`. It never presses a forge's Merge button, closes a PR, or gates on required checks. A protected default branch will refuse the push; use pull-request mode there. **Releasing — tags, changelogs, deploy pipelines — stays out of scope.**

**Configuration.** Each project sets a default finalize mode per target (plus the destination path for *Commit to path*); an individual task may override it. Approve → Done stays a **single primary button** whose label states the resolved mode — *Approve & open PR*, *Approve & merge*, *Approve & squash merge*, *Approve & hand over*, *Approve & commit artifact* — so the action bar never grows a menu and the button never promises something other than what runs.

A Done task can be **archived** to clear it from the board without deleting it (see §13).

---

## 7. Tasks in depth

- **One target per task.** A `repo`-target task works in exactly **one** repository (defaults to the project's default repo — the first one linked, or whichever a project with several has marked default). Work that spans repos should be **split** into one task per repo (see below); multi-repo tasks are out of scope for MVP.
- **Splitting (manual in MVP):** the user creates one task per repo/piece. The original umbrella task can't run (it spans repos), so it is either kept in Planning as a reference note or **deleted**. Parent/epic + sub-tasks is a later feature.
- **Delete:** a task with **no pushed artifacts** (in Planning, or Cancelled) can be deleted outright. This is distinct from **archive**, which retains a finished (Done) task.
- **Multi-run:** a `repo`-target task keeps one persistent worktree + feature branch that accumulates commits across review iterations — except the send-back-to-Planning reset. Each run is recorded as an audit step.
- **Attention** is a state on the task (type, detail, timestamp) set by event handlers (agent question, review ready, run failed) and cleared on human resolution. It surfaces as a card treatment plus a project sidebar counter — no per-user notification fan-out. In-app only for MVP (no email).
- Optional **assignee/owner** for small-team coordination. Optional human **comments** on a task.
- **Secrets:** an agent scaffolds config that *references* secrets but does not author secret **values**; real values live in the project env store and are injected at execution — never committed by the agent.
- **Archive:** a Done task can be archived, which hides it from the board and list views but retains it (description, spec, audit trail, reviews, pushed branch) so it can be searched and consulted later. Archiving does not delete and is reversible.

---

## 8. Agents

An agent is a reusable **persona** — e.g. "Judy," a frontend specialist. It bundles:

- **Role(s)** — what the agent can be slotted into: `execute`, `review`, `plan`, or any combination. A persona like "Judy" may execute and review; a dedicated "Security Auditor" is review-only; a "Surveyor" is plan-only. Slots filter the pool by role *and* work type. A role is the *slot*, never the *capability* — what an agent can actually do in that slot follows from its driver, which is why a `plan` agent on `llm_api` refines text while the same role on `acp` reads the repo.
- **Work type** — the kind of task it can take.
- **Driver** — how it runs: `acp` (a full coding agent like Claude Code or Codex over the Agent Client Protocol) or `llm_api` (a single model call, e.g. a local Ollama model, for review or short content).
- **Provider + model variant.**
- **System prompt** — persona, workflow, expertise, and standing preferences (e.g. Tailwind conventions).
- **Memory** *(schema seam only in MVP)* — a place for durable, learned preferences later. For MVP, persona-via-system-prompt plus a project markdown doc in the repo covers the need; the "learns how you work" behavior is deferred.

Agents live at **org level** (shared) or **project level**. Not every agent is a coding harness — a reviewer or content agent can be a cheap `llm_api` call. This keeps the model from being Claude-Code-shaped.

---

## 9. Providers & credentials

- Configured via **UI at the instance level** (not code/config files): Anthropic (subscription OAuth or API key), OpenAI, Ollama endpoint, etc.
- Credentials are **encrypted at rest**.
- Agents reference a provider + model variant. Usage and cost are tracked per provider.

---

## 10. Cost, tokens & budgets

- Every run's token usage and cost are **captured and persisted** (per task, and rolled up per project per day).
- **Budgets/limits** (money or tokens) can be set at **project** and **organization** level. A limit covers the **current calendar month (UTC)** and resets on the 1st — the number a user sets is what may be spent per month, not for all time.
- **MVP scope:** reliably track/persist usage and **enforce limits** — a task that would exceed a limit is *held* rather than started. The full review UI (per-project graphs by day/week/month/year) is iteration two, built on the same data.

---

## 11. MVP scope vs. later

**In MVP**
- Org/users with self-signup admin; projects with linked repos; org/project agents; UI-configured providers with encrypted credentials; project env store.
- Planning → Running → Review → Done workflow with selectable AI planning agents (text refinement and repo-aware survey), **multiple parallel advisory reviewers** (work-type matched, per-task, pre-filled from project defaults), human gates, cancel, and failure handling.
- Agent **roles** (`execute` / `review` / `plan`); separate executor, reviewer and planner slots on a task.
- Work types `code` / `design` / `content` / `file` driving agent selection, review surface, and Done.
- Coding execution via worktree + feature branch; non-coding via task folder; local-subprocess executor.
- Task **target** (`repo` / `folder`) decoupled from work type; content/design can land in a repo via branch/PR with a preview review.
- ACP-driven coding agents; `llm_api` agents for review/content.
- Multi-run rework loop with session/worktree continuity (fresh start on send-back-to-Planning).
- Done follows target **and finalize mode**: repo → commit / push, then PR/MR-or-compare, merge, or squash-merge into the default branch; folder → download or commit-to-path. Project default per target, per-task override.
- Usage/cost tracking + budget enforcement (data + limits, minimal display).
- First-run `/setup` wizard (gated by a `setup_done` flag): admin → provider → optional project + repos → optional agent. Max-concurrent-running cap.
- Board (Kanban default + list toggle), tabbed task view, and Settings / Profile / Projects / Agents pages (see §13).
- Delete a task in Planning/Cancelled; archive a Done task (hidden from board and list; retained).

**Designed-for-now, built later**
- Task **splitting / sub-tasks / epics** (MVP splitting is manual).
- Search across archived tasks; agent access to past tasks for prior solutions and fixes.
- Subscription-window queuing (auto-start when a token window resets).
- Container / user-selectable executors with resource caps.
- Review **walkthrough** (LLM steps through the diff explaining changes).
- Agent memory that learns preferences over time.
- Cost/usage dashboards and review pages.
- Planning / agent **modes** (ACP session modes — plan/ask). Orthogonal to the `plan` *role*, which shipped: role is the slot, mode is how a session runs.
- Plan mode as an execution sub-phase (an agent planning inside a run, before it edits).
- Cross-project queue ordering and priorities.
- Multi-repo tasks; timeline view.
- Agent marketplace and licensing/monetization. The entitlement *seam* has shipped (`CodeLead.License`, architecture spec §5.6) but declares no paid feature, so every instance runs as `:community` with everything enabled.

**Out of scope on purpose**
- Releasing: tags, changelogs, deploy pipelines. (Merging into the default branch *is* in scope — as local git, see §6.)
- Forge-side automation: auto-merge, closing PRs, required-check gating, review-approval rules.
- Enterprise features (fine-grained RBAC, SSO); multi-org-per-deployment.

---

## 12. UX principles

- **Task management first;** terminal and diff are a progressively disclosed developer view for power users.
- **Mobile-first responsive web UI;** sleek / minimal; DM Sans + JetBrains Mono; pastel brand palette; light/dark.
- **Guided first run** (`/setup`, gated by `setup_done`): create admin → connect provider → optional project + repos → optional first agent.

---

## 13. UI structure

Not a pixel spec — the page/tab map and the guarantee that each surface's data exists in the model.

### Main pages

**Board (home).** Kanban by default, with a toggle to a **list view** of the same tasks. Columns: Planning / Running / Review / Done. Cards show title, work type, priority, executor + reviewer indicators, and the attention treatment; a project sidebar carries the attention counter. Done cards expose an **Archive** action. Archived tasks are excluded from both board and list.

**Task view.** A tabbed page that **opens on the tab matching the task's current state**:

| Tab | Available | Primary in | Shows |
|---|---|---|---|
| **Task** | always | Planning | description, spec / acceptance criteria, work type, priority, owner/assignee, repository, executor + reviewer selection, ready flag, human comments, and the **AI planning surface** (planner selection; chat for an `llm_api` planner, "Run repo survey" for an `acp` one) |
| **Review / Artifact** | once Running | Review | live-updated diff (code) or rendered preview (design/content/file), plus each reviewer's findings and advisory verdict once the review cycle runs |
| **Agent** | once Running | Running | the **executor** conversation — live event stream, send messages, answer agent questions, approve surfaced permission escalations |
| **Developer** | once a worktree exists | — (power users) | terminal into the task's worktree (later: the container) |

In Planning only the Task tab is populated; the Agent / Review / Developer tabs come alive once the task starts running and its execution context is provisioned. Reviewer output lives on the Review/Artifact tab (reviewers aren't interactive); the Agent tab is the executor only.

### Secondary pages

- **Settings** (instance / admin): users, providers + credentials, organization budget limits, instance config (e.g. max concurrent runs).
- **Profile** (per user): language, theme (light/dark), UI preferences.
- **Projects**: create/edit projects, link repositories (mark one the project's **default repository** for `:repo`-target tasks), project env store, project budget limits, project **default reviewers** per work type, and an editable **PR template** for the description used when Approve opens a pull request (defaults to a built-in template).
- **Agents**: create/edit agents — roles, work type, driver, harness, provider + model, system prompt, memory (seam) — with a scope selector for org vs project.

