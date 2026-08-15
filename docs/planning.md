# Planning surface (last updated: 2026-08-15, surveys stay local)

Implemented in `CodeLead.Planning`, rendered by the Task tab's chat card
(`CodeLeadWeb.TaskLive.TaskTab`). The planning conversation helps the
human sharpen a task's description and spec before anything runs.
Nothing here moves the card and nothing here edits the task — the
output crystallizes only when the human writes it into the spec.

## Role, not mode

A planning agent is an ordinary agent with `:plan` in `roles`, filtered
into the surface by role **and** the task's `work_type`, exactly like
executors and reviewers (`Agents.eligible_planners/2`). The **driver**
decides what it can do in that slot:

| Driver | Entry point | Capability |
|---|---|---|
| `:llm_api` | `Planning.send_message/3` | text-only refinement: task fields plus a repository file listing, one completion |
| `:acp` | `Planning.start_survey/2` | **repo-aware survey**: reads current default-branch source read-only and reports what the spec leaves out |

Role (*which slot*) and mode (*how an ACP session runs*) are separate
axes on purpose. There is no `mode` field and no ACP session mode; the
survey is a normal ACP run with a "survey, don't write" prompt.

A `:plan` agent is **not** an executor. The Planning → Running guard is
keyed on `:execute`, so having only a planner does not let a task start.

## The survey is the reviewer primitive, moved upstream

A reviewer reads the *diff* and critiques the *output*. A surveyor reads
the *existing codebase* and critiques the *spec*. Same
`CodeLead.AdvisoryRun`, same read-only posture, same advisory status —
see [`reviews.md`](reviews.md). Only two things differ:

- **When it runs.** A human pulls it from the Planning workbench. It is
  not a transition effect, not a gate, and it does not move the card.
- **Where its output lands.** A `planning_messages` turn with
  `kind: :survey`, not a `reviews` row. The `reviews` table is for
  post-artifact review.

The run is real: an `agent_runs` row (cost) and a `:plan` `task_steps`
row (audit). Cost-tracked, **not** budget-gated — it never reaches
`Scheduler.admit?/1`, the same call the reviewers skip. If survey cost
becomes a concern it belongs in the gate list beside the others (see
[`task-workflow.md`](task-workflow.md)).

## Survey execution context

A survey reviews net-new work against current mainline, so it needs no
feature branch and no execution worktree — only read-only access to
current default-branch source. It gets the cheapest thing that provides
that: a **disposable detached worktree**
(`Git.create_detached_worktree/3` → `<root>/surveys/task-<id>`), removed
when the run ends, including on crash. Surveys always run on the
**local** executor, whatever the task's `execution_env` says — the
survey worktree has no container, and never should.

Two reasons it is not the base clone itself:

- `Git.ensure_clone/3` only *fetches* an existing clone — never `pull`,
  `reset`, or `checkout` — so the base clone's own working tree is
  frozen at the commit it was first cloned at. A worktree started from
  `origin/<default_branch>` is what sees current source.
- `read_only: true` denies `fs/write_text_file` but not `terminal/create`
  (see [`reviews.md`](reviews.md)), so a survey pointed at the shared
  base clone could dirty the clone every task branches from.

Invariants, each structural rather than conventional:

- **No feature branch** — `git worktree add --detach`, so there is no
  branch to commit to and none to clean up.
- **Nothing committed or pushed** — no such call exists on this path.
- **The execution session is untouched** — the run is handed
  `%{task | acp_session_id: nil}`, because `AgentDriver.Acp` resumes
  `task.acp_session_id` via `session/load` when it is set.
- `<root>/surveys/` is dropped by `mix code_lead.workspace.clean`
  (wired into `mix ecto.reset`), like `worktrees/` and `tasks/`.

## Messages

`planning_messages` carries `role` (`:user` | `:assistant`), `kind`
(`:chat` | `:survey`) and `agent_id`. Only `:chat` turns are replayed as
history into later `llm_api` completions — a survey report is a
standalone artifact, and replaying a multi-KB report would resend it in
full on every subsequent turn.

## Attention

Normal completion raises **no** attention: the human pulled the survey,
and `{:survey_completed, _}` on the task topic is enough for an open
LiveView. A question or a permission escalation raises the ordinary
`attention` field through the same mechanism every agent uses — no new
type, no new machinery.

**Known gap.** An advisory run's escalation surfaces but is not
answerable. The Allow/Deny buttons route through
`Runtime.answer_permission/3` → `RunSupervisor.whereis/1`, which finds
only executor runs; an advisory run is not in `CodeLead.Runtime.Registry`
(keyed on task id, where it would collide with the executor run). Such a
run ends on `AdvisoryRun`'s deadline. Wiring interactive answering for
advisory runs is a separate change.

Questions are answerable on the executor path — `{:question, _}` is
emitted from an ACP elicitation and settled with
`Runtime.answer_question/3` (see [`agent-drivers.md`](agent-drivers.md)).
An advisory run cannot receive one at all: it provisions a **read-only**
context, and the driver withholds the elicitation capability there, so
the harness keeps its ask-the-human tool disabled. That is deliberate —
an unanswerable question would only stall the survey until its deadline.
The `{:question, _}` branch in `AdvisoryRun` stays for drivers that
might escalate by other means, and raises attention without a `ref` so
the UI offers nothing to submit.
