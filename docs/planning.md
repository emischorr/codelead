# Planning surface (last updated: 2026-08-24, task-level refinement, no chat UI)

Implemented in `CodeLead.Planning`, rendered by the Task tab's Planning
agent card (`CodeLeadWeb.TaskLive.TaskTab`). A one-shot agent
refinement helps the human sharpen a task's description and spec before
anything runs. Nothing here moves the card and nothing here edits the
task — the output crystallizes only when the human writes it into the
spec.

## Role, not mode

A planning agent is an ordinary agent with `:plan` in `roles`, filtered
into the surface by role **and** the task's `work_type`, exactly like
executors and reviewers (`Agents.eligible_planners/2`). One entry
point, `Planning.start_refinement/2` — the **driver** decides the
refinement's depth in that slot:

| Driver | Depth | Capability |
|---|---|---|
| `:llm_api` | **Task level** | one completion over the task fields plus a repository file listing (`refinement_prompt/1`); no repository required |
| `:acp` | **Repo level** | **repo-aware survey**: reads current default-branch source read-only and reports what the spec leaves out |

Both depths produce the same two-part report — markdown narrative plus
findings JSON tail — recorded as a `:plan` step (`repo survey: <status>`
vs `task refinement: <status>`; both prefixes feed
`Findings.survey_run_count/1` and display as "Refinement
completed/failed"). There is deliberately **no chat interface** in the
web UI; the conversational loop (`Planning.send_message/3`,
`Planning.chat/2`) remains available from the IEx console only, and
old `:chat` planning messages are kept in the database but no longer
rendered.

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

## Findings

A survey report is more than prose: its output contract is a markdown
narrative followed by exactly one fenced ```json block, which
`CodeLead.Findings.Report` parses into **findings** — persisted,
severity-labelled rows (`findings` table, `CodeLead.Findings` context),
one per item, keyed to the task and the producing `:plan` step. The raw
turn stays on `planning_messages` exactly as before; findings are parsed
*from* it, not instead of it.

Parsing is deliberately lenient, because the contract is a text
convention rather than a provider feature — CodeLead speaks ACP to
harnesses whose structured-output support differs, so the parser, not
the protocol, absorbs formatting drift. Extraction runs three tiers and
gives up only when none yields a report-shaped object:

1. the last ```json marker, then a balanced-brace scan from there;
2. every `{` in the report — outermost objects, latest first;
3. the same candidates run through a repair pass that escapes stray
   double quotes inside string values (logged at `:info` when it fires).

Neither the fence's position nor its closing half is required, so a
block glued to the end of a sentence, opened with its payload on the
same line, or left unterminated still parses. A candidate is accepted
only when it carries a `"findings"` or `"prior"` key, which stops a
nested item object from standing in for the whole report when the outer
object is the malformed one. Tier 3 is a heuristic — a body carrying a
quoted phrase immediately followed by a comma is still misread — so it
is a strict improvement over failing, not a guarantee.

Within an accepted payload, items without a title are dropped and
unknown severity defaults to `:medium`. A report that survives none of
the tiers writes nothing, logs a warning, and renders the turn as
markdown behind a "could not parse findings" hint. An advisory run never
fails because the model got the tail wrong (the same graceful
degradation as the reviewers' trailing-verdict convention in
[`reviews.md`](reviews.md)).

There is deliberately no gap/contradiction/assumption taxonomy on the
row. The prompt also scopes the report: the agent is told to assume
general knowledge of the project and to skip broad or obvious
observations — only things someone scoping this specific task would
act on. The three lenses live only in the prompt; the classification axes
are `severity` (`:high | :medium | :low`, agent-assigned) and `phase`
(`:planning | :review`, system-assigned — reviewers reuse the same table
in a later iteration, which is why the parser and renderer are
phase-agnostic).

**Two owners, one row.** The agent owns the observation side —
`observed` (`:open | :resolved | :not_applicable`) plus
`first_seen_step_id`/`last_seen_step_id`. The human owns the resolution
side — `resolution` (`:addressed | :dismissed`), `resolution_note`,
`resolved_by_id`, `resolved_at`. A later run may reclassify the
observation; it can never set, clear, or change a resolution. When a
run *after* the human's resolution still flags the item, the UI shows a
subtle "agent still flags this" marker; the tick stays. The timing
matters (`Finding.still_flagged?/2` compares `resolved_at` against the
latest survey step): the run that produced the finding proves nothing
about a resolution made while reading it. What a row displays as is
derived from both sides (`Finding.display_state/1`), never stored.

**Reconciliation is the agent's job.** A re-run's prompt lists every
prior finding — open, addressed, dismissed, obsolete — with its id and
any human note, and the report classifies each in a `"prior"` list
(`still_open` / `resolved` / `not_applicable`) instead of re-reporting
it. The app applies the classification and inserts only the genuinely
new items; nothing in Elixir tries to fuzzy-match titles. A prior
finding the report omits keeps its previous observation untouched —
omission means nothing.

**Resolutions flow into prompts.** `Findings.decisions_block/1` renders
noted `:addressed` resolutions under `## Decisions` and noted
`:dismissed` ones under `## Out of scope`; a resolution without a note
flows nowhere, and an empty block injects nothing. That is why the UI
requires a note to address (Save stays disabled, and the LiveView
refuses a blank one) but leaves it optional to dismiss — an addressed
finding without a decision text would be a tick that changes nothing. The block is appended
to the fresh-dispatch executor prompt (`TaskRunner.build_prompt/1` —
not the request-changes rework prompt, whose carried session already saw
it), the review prompt, and both refinement prompts (survey and
task-level, plus the console chat preamble). The Task card shows the
block read-only beneath the spec
— what the user sees there is exactly what is injected. "Add to spec"
on a finding pre-fills the edit form; nothing writes the task silently.

**Surface.** One Planning agent card on the Task tab carries the whole
lifecycle: the agent select (suffixed `· Repo level` / `· Task level`
by driver) and the one "Run agent refinement" button in a single row on
top — same button either level, disabled for a repo-level agent until a
repository is linked — and, once a run has reported, the rows as an
expandable checklist (severity chip, cited paths as forge links where
`Git.forge/1` recognizes the host, obsolete items folded away), with
the report narrative collapsible above and the raw turn behind a "show
raw report" toggle. Actions exist only while the task is in Planning;
afterwards findings are a read-only record of why the task is shaped as
it is. Resolutions broadcast `{:findings_changed, _}` on the task
topic, so every open LiveView sees a tick as it happens. The "run N"
counter is derived from the refinement `:plan` steps, never stored; a
step's stored summary stays the technical `repo survey: <status>` /
`task refinement: <status>` (they are that counter's match keys) and is
rendered as "Refinement completed/failed" by
`CodeLeadWeb.Format.step_summary/1`.

## Messages

`planning_messages` carries `role` (`:user` | `:assistant`), `kind`
(`:chat` | `:survey`) and `agent_id`. Both refinement depths append a
`:survey` turn — the raw transcript and the source of findings: the row
keeps the full content (narrative plus JSON tail), while the card
renders the parsed pieces and offers the raw report behind a toggle.
`:chat` turns exist only through the IEx console loop and are not
rendered in the web UI; only they are replayed as history into later
console completions — a report is a standalone artifact, and replaying
a multi-KB report would resend it in full on every subsequent turn.

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
