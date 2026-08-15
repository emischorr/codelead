# Web UI (last updated: 2026-08-15)

The web layer: the Kanban board, the task page, and the settings
area — all LiveViews. Product spec §13 is the target; this note maps
what exists today.

## Routes

| Route | Module | Purpose |
|---|---|---|
| `/` | `CodeLeadWeb.DashboardLive` (`:index`) | org-wide dashboard; the onboarding card when no projects exist |
| `/projects/:project_id/board` | `CodeLeadWeb.BoardLive` (`:index`) | the Kanban board |
| `/projects/:project_id/board/new` | `CodeLeadWeb.BoardLive` (`:new`) | new-task modal (patch-based) |
| `/projects/:project_id/tasks/:id` | `CodeLeadWeb.TaskLive` (`:show`) | task page; `?tab=task\|agent\|diff\|terminal` |
| `/settings` | `CodeLeadWeb.SettingsLive` (`:index`) | overview tiles with live counts |
| `/settings/users` | `CodeLeadWeb.SettingsLive.Users` | list; `/new` and `/:id/edit` are patch-based modals |
| `/settings/providers` | `CodeLeadWeb.SettingsLive.Providers` | list; `/new` and `/:id/edit` |
| `/settings/agents` | `CodeLeadWeb.SettingsLive.Agents` | org- and project-scoped agents; `/new` and `/:id/edit` |
| `/settings/projects` | `CodeLeadWeb.SettingsLive.Projects` | list; `/new` |
| `/settings/projects/:id` | `CodeLeadWeb.SettingsLive.Project` (`:show`) | details, approve defaults, PR template, repositories, env store, this project's own agents, default reviewers |
| `/projects/:project_id/tasks/:id/artifact` | `CodeLeadWeb.TaskArtifactController` (`:download`) | a folder task's task folder, zipped |
| `/setup` | `CodeLeadWeb.SetupLive` (`:index`) | first-run wizard, only while `setup_done` is false |
| `/users/*` | `CodeLeadWeb.UserLive.*` | log in, magic-link confirmation, account settings (email/password, plus personal preferences: language, timezone, theme) |

The project detail page also carries four patch-based sub-routes:
`/repositories/new`, `/repositories/:repository_id/edit`, `/env/new`
and `/env/:key/edit`. `/settings/projects/new` is declared **before**
`/settings/projects/:id` so the literal is not swallowed by the param.

All of the above except `/setup`, `/users/log-in` and the artifact
download live in `live_session :require_authenticated_user` behind both
the setup gate and the auth gate. The artifact download is a
**controller** route, which cannot live inside a `live_session`, so it
sits in the same authenticated scope beside `post
/users/update-password` — same pipeline, same gates — see [`setup-and-auth.md`](setup-and-auth.md). All of them
render the same sidebar from the `@nav` map assigned by
`CodeLeadWeb.NavContext` — see [`navigation.md`](navigation.md).

**There is no authorization.** Every signed-in user can reach every
settings page and delete any user, provider, agent or project.
`users.role` is stored and displayed but nothing reads it — the Users
page shows the role as a badge and deliberately offers no way to change
it, rather than implying enforcement that does not exist.

## Settings

One LiveView per section, each using `live_action` for its create/edit
modal, following `BoardLive`'s new-task modal. The exception is the
project **detail** page, a full page because it hosts four independent
sub-surfaces (its own dialogs are patched over it).

`CodeLeadWeb.SettingsLive.Components` holds what the component library
lacks — there is no table and no modal component: `settings_page_header`,
`settings_tile` (a tile without `navigate` renders as a disabled
placeholder — that is how the Organization tile is drawn),
`list_row`, `modal`, `delete_button` (inert with a `reason`) and
`secret_value`. `list_row` and `modal` are general enough to belong in
`UIComponents`; promoting them means also refactoring `BoardLive`'s
hand-rolled modal, so that is a follow-up.

`CodeLeadWeb.FormOptions` holds the select options and credential label
copy that the wizard and the settings pages share, so the two surfaces
cannot drift. `CodeLeadWeb.FlashMessages.delete_error/1` renders the
guarded-delete refusals.

**Secret inputs carry `autocomplete="new-password"`**, plus
`data-1p-ignore` / `data-lpignore` / `data-bwignore`. A password field
preceded by a text field looks like a login form, and browsers
deliberately ignore `autocomplete="off"` there — so the provider modal
would open prefilled with whatever the password manager had saved.
Only `new-password` suppresses the fill; the `data-*` attributes are the
opt-outs for 1Password, LastPass and Bitwarden, which run their own
heuristics. The text field ahead of a secret gets `autocomplete="off"`
so it is not treated as the username half of the pair.

**Deletes are guarded in the context, not the UI.** The relevant foreign
keys nilify or cascade, so an unguarded delete would silently strip
executors off tasks or erase a project's whole history rather than
raising. `Agents.provider_usage/1`, `Agents.agent_usage/1`,
`Projects.project_usage/1` and `Projects.repository_usage/1` are
load-bearing; the disabled button is only the explanation.

**Secrets never reach the browser.** The providers page reduces each row
to `%{credential_set?: bool}` before it hits an assign, because
`providers.config` decrypts on load. The project env store lists through
`Projects.list_env_keys/1`, which selects a bare map so Cloak's load
callback never runs — `env_vars/1` would hand back every plaintext value.
Both surfaces are write-only: a stored value can be replaced, never read
back.

The agent form's **Project** select drives `scope`: left on "All
projects" the agent stays org-wide (`Agents.list_all_agents/0` and the
row's scope badge both read this), picking a project sets `scope:
:project` and casts `project_id` — `Agent.changeset/2` casts it directly,
so moving an agent between scopes is a normal edit, not a dedicated
function. The project detail page's **Agents** tile
(`Agents.list_project_agents/1`) surfaces only that project's own
agents — org-wide ones stay selectable there without cluttering the
list — and links back to `/settings/agents` to manage or add one.

Deferred here: the Organization tile is a placeholder because
`Accounts.update_organization/1` replaces `settings` wholesale and would
clobber `setup_done`; editing budgets there needs a merging setter first.

## Design language

Tokens live in `assets/css/app.css`: a raw palette on `:root` /
`:root[data-theme=dark]` (surface/border/text tiers, accent, run/warn/
ok, diff add/del, terminal), mapped through a Tailwind v4 `@theme`
block so utilities like `bg-surface`, `text-text2`, `border-border`
theme-switch without `dark:` prefixes. The default Tailwind palette is
dropped (`--color-*: initial`) to enforce token usage. Two custom
variants carry state that the server does not own: `dark`
(`[data-theme=dark]`) and `collapsed`, which resolves the sidebar width
from `<html data-nav>` and `#sidebar[data-sidebar]` — see
[`navigation.md`](navigation.md). Fonts are
self-hosted variable DM Sans (UI) and JetBrains Mono (numbers/code) in
`priv/static/fonts/`. daisyUI was removed; the scaffold components in
`core_components.ex` (flash/button/input) are hand-styled on tokens.

Agent prose is markdown, rendered by `CodeLeadWeb.Markdown` (MDEx) and
styled by a hand-written `.md` block in `app.css` — the typography
plugin is not used, because `--color-*: initial` removes the palette its
defaults are built on. Agent output is untrusted, so the wrapper renders
with `unsafe: false` **and** sanitizes; no call site may opt out.

The theme script in `root.html.heex` resolves "system" to a concrete
`data-theme=light|dark` (tracking `prefers-color-scheme`) and stamps
`data-theme-mode` for the toggle indicator.

**The shell owns the viewport height.** `Layouts.app` opens with `h-dvh
overflow-hidden` and its `<main>` is `flex flex-col overflow-hidden`, so
the window itself never scrolls: page headers stay put by construction
and `sticky` actually works. The contract that follows is that **every
page under `Layouts.app` must put its content in a `min-h-0 flex-1
overflow-y-auto` pane** — a page that forgets it gets clipped, not a
scrollbar. The board, dashboard and task page each have one; the
settings family wraps its `mx-auto max-w-*` column in one (the classes
stay on separate divs, because `flex-1` on the centred column would
stretch it and make `max-w-*` size the scroller instead).

The sidebar follows the same rule internally. The `<aside>` keeps
`overflow: visible` — the project switcher's flyout has to escape the
232px/64px column — so the scroll region is the nav-links div inside it,
`min-h-0 flex-1 overflow-y-auto`. That `flex-1` is also what pins the
budget and account cards to the bottom of the viewport (it replaced a
bare `flex-1` spacer); everything above and below it is `shrink-0`, so a
short viewport squeezes the links rather than the chrome.

## Component inventory

- `CodeLeadWeb.UIComponents` (imported in `html_helpers`): `badge`,
  `state_badge`, `agent_pill` (harness dot: claude_code `#D97757`,
  codex run, other accent), `pulse_dot`, `cost_stat` (`cost_cents`,
  `tokens`, `duration_ms`, `cost_mode`), `section_card`,
  `attention_banner`, `timestamp`, `timeline_start`, `timeline_entry`,
  `tab_nav`, `kanban_column`,
  `task_card` (shell + column-specific `footer` slot), `chat_bubble`,
  `empty_state`, `schedule_modal` (the "start at (UTC)" dialog shared by
  `BoardLive` and `TaskLive`; the caller owns the `schedule_task` /
  `close_schedule` events, and `CodeLeadWeb.ScheduleForm` supplies the
  schemaless changeset behind it),
  `fab`, `stat_tile` (icon chip + headline number +
  detail, five tones, optional `navigate` and `meter` slot) and
  `meter` (a value against a limit; renders nothing without one —
  `Layouts.budget_card` and the dashboard both draw their bars with it).
  `stat_tile` is deliberately not `SettingsLive.Components.settings_tile`:
  that one is a navigation affordance with a disabled "Coming soon"
  variant and a pre-stringified stat, not a readout.
- `CodeLeadWeb.DiffComponents`: `file_list` (jump buttons, active
  state), `file_diff` (collapsible header, dual line-number gutters,
  add/del row tints) over `CodeLead.Git.Diff` parser structs, plus
  `file_dom_id/1` — the shared card id, Base64 rather than a slug so
  `a/b.ex` and `a-b.ex` cannot collide on one scroll target.
- `CodeLeadWeb.Layouts.app`: sidebar navigation — one collapsible
  sidebar on desktop (232px expanded, 64px glyph rail collapsed, toggled
  by `#sidebar-collapse` and remembered in `localStorage["cl:nav"]`),
  overlay drawer on mobile (`Layouts.sidebar_toggle` opens it). Takes
  `flash`, `nav`, `current_scope` and optionally `sidebar`
  (`:user` follows the preference, `:open`/`:closed` override it and hide
  the toggle — `TaskLive` passes `:closed`); no context calls in the
  layout. The `nav` map and the rules the sidebar renders by are
  documented in [`navigation.md`](navigation.md).
- `CodeLeadWeb.Layouts.auth`: the chromeless shell (wordmark + theme
  toggle + centered column, `width` configurable) used by the setup
  wizard and the auth pages.
- `CodeLeadWeb.Format`: `cents/1`, `tokens/1`, `cost_tokens/2`,
  `cost/2`, `duration/1`, `run_stat/4`, `relative/1`, `absolute/1`,
  `iso8601/1`, `time/1`.
  `run_stat/4` is the standard run readout (`$2.07 · 183.5k · 2m 14s`)
  and drops segments with nothing to say rather than printing dashes,
  so a subscription-free run reads `183.5k · 2m 14s`.
  `CodeLeadWeb.FlashMessages` maps `Tasks.transition_error/0` reasons
  to flash text.

## DashboardLive

The landing page at `/`, org-wide across every project. Five rows, in
the order a human triages: attention tiles (needs approval, failed runs,
agents running, stalled runs) → a 14-day throughput chart plus lead
time and spend tiles → active runs and the attention queue → recent
completions and the cross-project activity feed → a per-project
pipeline breakdown. With no projects it renders an onboarding card
inside `Layouts.app` — the sidebar stays, because there is somewhere to
navigate to (`/settings/projects/new`).

**Everything on it is live.** Metrics the model cannot back are absent
rather than mocked: no "autonomous success" rate (rework would mean
string-matching audit prose), no per-agent token counters, and no
quick-links row — the sidebar already owns navigation.

It does **not** call `NavContext.put_stats/3`. The sidebar's attention
pill and budget tile are project-scoped, and pointing them at one
arbitrary project's board from an org-wide page would be wrong; the page
carries its own readouts instead.

Three refresh mechanics, all load-bearing:

- `Tasks.subscribe_org/0` — one subscription to `"org:tasks"` rather
  than N board topics, so a project created after mount is covered.
- A trailing-edge debounce (`@refresh_ms 800`, one armed timer at a
  time, the shape `TaskLive.schedule_diff_refresh/1` uses). A run
  produces a burst of transitions; they coalesce into one reload of
  ~17 grouped queries. Tests must send `:refresh` explicitly — asserting
  straight after a change, as `BoardLiveTest` does, sees stale content.
- A 30s `:periodic` tick. `Costs.record_run/1` broadcasts nothing at
  all, so without it spend, the spend chart and the per-project costs
  would freeze at mount. It also re-renders relative timestamps and
  rolls the page over UTC midnight.

"Stalled runs" cross-checks `Tasks.active_runs/0` against
`RunSupervisor.active_task_ids/0`: a task persisted as `:executing`
whose id has no runner process has lost it.

The lead-time tile is labelled **"Avg lead time · created → approved"**,
not cycle time — `Tasks.avg_lead_time_ms/1` includes however long the
task sat in Planning waiting on a human.

Panels live in `CodeLeadWeb.DashboardLive.Widgets`. Both charts are the
same `bar_chart/1`: pure CSS, no library and no asset. The bar *is* the
flex item, because a percentage height resolves against the flex line
and only the container's fixed height makes that definite; `min-h-[2px]`
gives an empty day a baseline tick. Color encodes exactly one thing —
whether the point is today.

## BoardLive

Plain assigns (whole-board reload); `Tasks.subscribe_board/1` +
`{:board_changed, _, _}` → `load_board/1`, which batch-loads
`Costs.spend_by_task/1`, `Reviews.verdicts_by_task/1`,
`Tasks.commit_notes/1`, and queue positions from `Tasks.queued_tasks/0`
(tasks waiting on a future `scheduled_at` are excluded from the
numbering — they are not in line behind anything).
No drag & drop — explicit Start (planning footer) and Archive (done
footer) actions. It was considered and turned down. A board move here is
not the harmless reordering it is in a generic issue tracker: every edge
fires automation and encodes a human decision — Planning→Running
dispatches an agent, Review→Planning discards the worktree, branch, and
session, Review→Done commits, pushes and then opens a PR or merges the
branch outright, depending on the task's finalize mode. The moves that
would most want a gesture are also the ones you cannot decide from a
card — judging a review means reading the diff and the verdicts, so you
are on the task page already, where `header_actions/1` carries the full
set. What is left is the fast, obvious moves, and those already have
per-edge buttons on the card. A generic move gesture would only add a
second, weaker trigger for transitions that deserve a deliberate one.
A done card whose finalizer produced a forge link also
shows it (`<card_id>-forge-link`), labelled PR / MR / Commit / Compare
from `tasks.pr_url_kind` — the URL comes off the task, not from
`board_ctx`. A done `:folder` task shows a **Download**
(`<card_id>-artifact-link`) instead; a card never has both, which is
what the single `ml-auto` in the footer assumes. The planning footer's Start is a split control: the
clock button opens the shared `schedule_modal` and starts the run at a
chosen UTC time instead of now. Both are hidden — not just disabled —
when `Tasks.startable?/2` is false: no eligible executor, or a `:repo`
target with no repository, the same guard `move_to_running/1` would
otherwise reject the transition on. A queued task with a future
`scheduled_at` shows `⏱ starts …` in place of the `⏸ queued · #N`
badge, derived from the task rather than from a persisted hold reason.
On desktop **each column scrolls on its own**: the pane is
`lg:overflow-hidden`, the grid is `lg:h-full` (no `items-start`, so the
columns stretch), and the cards sit in a `min-h-0 flex-1 overflow-y-auto`
div below a `shrink-0` header. The action bar and all four column
headers therefore stay fixed, and a long Planning column does not push
the other three down. Below `lg` the same markup is inert — with no
definite height above it the inner `flex-1` resolves to auto, so the
single column grows and the pane scrolls it.
Mobile: segmented one-column switcher + FAB (DOM ids
prefixed `m-`); card button ids are derived from the card's own id so
the two renderings do not collide. New-task modal validates work_type
against `Agents.eligible_executors/2`.

## TaskLive

Tab from `?tab=`, defaulting by state (planning→task, running→agent,
review→diff, done→task). Tab bodies are plain `Phoenix.Component`
modules under `task_live/` (`TaskTab`, `AgentTab`, `DiffTab`,
`TerminalTab`). All actions go through `CodeLead.Runtime`; errors map
to flashes.

Header actions are chosen by `{state, run_state}` plus a precomputed
`scheduled?` flag: planning offers **Schedule** (`#action-schedule-run`,
opening the shared `schedule_modal`) alongside **Start run**, both
`disabled` with the reason as their `title` when `Tasks.startable/2`
(precomputed as `@startable_reason` in `load_task/1`) returns an
error instead of `:ok` — unlike the board card, the task page keeps
them visible so the tooltip can explain why. A queued task whose start
time has not arrived offers **Run now**
(`#action-run-now`, `Runtime.run_now/1`) beside Cancel run. A
`#scheduled-hint` badge next to the state badge shows the start time. A
done task carrying a forge link renders **Open PR / MR / Commit /
Compare** (`#action-open-pr`, from `tasks.pr_url`/`pr_url_kind`) left of
**Archive**, as an external `<.button href=… target="_blank">`; a done
`:folder` task also gets **Download** (`#action-download-artifact`).

In Review the primary button is labelled from the task's **resolved
finalize mode** — *Approve & open PR* / *& merge* / *& squash merge* /
*& hand over* / *& commit artifact* — via `Format.finalize_action/2`,
with `Format.finalize_hint/2` as its tooltip. `#action-approve` stays a
single button whatever the mode; the mode itself is picked on the Task
tab, not in the bar. The `forge_known?` flag it takes is precomputed in
`load_task/1` (`Git.forge(git_url) != :other`), because a remote with no
forge convention can be pushed to but not opened a PR on — there the
label reads *Approve & push branch*.
One `header_actions/1` clause feeds both the desktop toolbar and the
mobile bar, so ids come from `action_id/2` (`m-` prefixed on mobile).

The mobile bar is an in-flow `shrink-0` flex child of `<main>`, not
`fixed` — it shortens the scroll pane above it rather than covering it.
Tab panes therefore add **no** bottom padding to clear it (the pane used
to carry `pb-24`), and a tab that docks its own bottom chrome lands
above the bar instead of underneath it.

- **Task tab** — attention banner (with Allow/Deny when a permission
  `ref` is stored; Answer/Skip when a question one is — Answer patches
  to the Agent tab rather than duplicating the form, Skip declines in
  place. Both stay hidden without a `ref`, which is how an advisory
  run's unanswerable escalation renders), description/spec (edit form in planning via
  `planning_changeset`; edit mode is the `editing?` assign toggled by
  `toggle_edit`, not a `JS.toggle` — a save or a background re-render
  would otherwise leave the form open over stale values, and
  `load_task/1` conversely leaves an open form's contents alone).
  The same planning-only actions row carries `#delete-task`, a
  `data-confirm`-guarded hard delete (`Tasks.delete_task/1`) that
  redirects to the board on success and flashes
  `FlashMessages.delete_error/1` on refusal — the guard is the context
  function's `state in [:planning, :cancelled]` match, the UI only
  shows the link in Planning,
  the planning surface (`#planner-form` selects
  a `:plan` agent from `Agents.eligible_planners/2`; an `:llm_api` pick
  shows `#chat-form` — `Planning.send_message/3` is synchronous →
  `start_async` — and an `:acp` pick swaps in `#run-survey`, which
  fires `Planning.start_survey/2` and waits for `{:survey_completed, _}`
  on the task topic; survey turns render with a provenance label. The
  selected planner lives in the socket, not on the task — see
  [`planning.md`](planning.md)), timeline
  (`Tasks.steps/1` on a vertical rail, opened by a `timeline_start`
  node synthesized from `task.inserted_at` — no `:created` step row
  exists; every timestamp carries a UTC `title` that the `.LocalTime`
  colocated hook rewrites to the viewer's zone),
  executor/reviewer selection (planning) or verdict
  list, the target card, per-run cost/token/duration rows
  (`Costs.task_runs/1`, with the token split on hover).
  The **execution shape** — work type, target, repository, execution
  environment — is editable
  only in Planning, and is split across two surfaces: work type is a
  select in `#task-edit-form` (it stays a chip in the read view), while
  target, repository and the Local/Container execution select live in
  `#target-card` on the rail between
  Executor and Cost. `#target-form` is a bare `phx-change` form like
  `#executor-form`, so `set_target` saves on every change with no Save
  button; the repository and execution selects only appear for a
  `:repo` target (a folder task is structurally local), and
  switching to `:folder` leaves `repository_id` alone because the
  `:commit_to_path` finalize mode still uses it. Container execution is
  the one licensed feature, so on an instance without a granting
  `LICENSE_KEY` the Container `<option>` renders `disabled` (never
  dropped — a task already set to Container would otherwise show Local
  and misreport itself) under a one-line note, and the Start button's
  tooltip carries the `:unlicensed_execution_env` copy; see
  [`licensing.md`](licensing.md). A Container task whose
  repository declares no image is not startable either — that tooltip
  carries the `:missing_execution_env` copy instead. The repository
  modal in project settings is where the image is declared (not itself
  gated: declaring an image is a repository property) — a single
  image-reference field (`env_kind` is derived from it: set = container
  environment declared, cleared = local-only), with a
  `container: <ref>` badge in the repo list. Outside Planning the
  card turns into read-only rows plus the branch name. The same card
  carries the **On approve** selector (`#finalize-form`, another bare
  `phx-change` form) until the task is Done: its first option is
  *Project default · \<mode\>* with an empty value, so clearing the
  override is distinguishable from choosing the project's current mode.
  A done `:folder` task shows its download here too
  (`#task-artifact-link`). Both surfaces go through
  `Tasks.update_task/2`, which re-normalizes a Planning edit: a `:repo`
  target with no repository falls back to the project's first one, and a
  new work type drops an executor that is no longer eligible and
  re-prefills the reviewer set from the project defaults.
- **Agent tab** — the executor transcript from `AgentFeed.list_run/2`
  (the current run; "Show earlier runs" switches to `list_all/2`), never
  from task steps. `CodeLeadWeb.TaskLive.AgentFeedBlocks.fold/2` groups
  consecutive `:tool_call` rows into one collapsible block keyed by its
  first row's id; `apply_row/2` applies each incoming `{:agent_feed, _,
  row}` and returns just the blocks to re-`stream_insert`. Re-inserting
  an existing stream id updates in place without moving the element, so
  a tool call advancing `pending → completed` stays put. A block closing
  auto-collapses the previous group unless the human pinned it via
  `toggle_block`. The row the runner is still writing (`streaming:
  true`) renders in `#agent-live-message` outside the stream, where
  `{:task_event, _, {:message_chunk, _}}` appends to it cheaply; the row
  broadcast replaces that text wholesale and is always authoritative.
  Permission Allow/Deny render only while the run is executing and the
  row has no `data["resolved"]` — `answerable?/2`, which a `:question`
  row shares. Composer is disabled: the ACP driver's mid-run
  `send_message` is a stub.

  Like the Diff tab, this tab owns its scrolling: the root is `h-full
  min-h-0 flex-col`, `#agent-pane` is the `min-h-0 flex-1
  overflow-y-auto` scrollport, and the composer is a `shrink-0` sibling
  *outside* it. The composer must not go back to `sticky bottom-0` — a
  sticky element cannot leave its containing block, and with the feed
  scrolling in the page pane that block is one screenful tall, so the
  composer detaches and paints over the transcript's tail (which on a
  short viewport buries an unanswered question's buttons for good).

  Tool rows read `label: detail`, and the detail is shortened against the
  run's working directory (`context_root/1` — the worktree for a `:repo`
  task, the task folder for a `:folder` one) via
  `Format.project_path/2`. A path with no leading slash is therefore
  inside the project; one still absolute is the signal that the agent
  reached outside it. Only `data["locations"]` and absolute
  `data["input"]` values are rewritten — command strings are free text
  and left verbatim. The stored event keeps the absolute path, which the
  ACP sandbox check depends on.

  A `:question` row is the one entry a human acts on directly, so it
  renders the agent's own form rather than a message: `#…-answer-form`
  holds a radio group per single-select field (checkboxes for
  multi-select, each option showing its label and description), a text
  input for the free-text and "Other" fields, and `#…-answer` /
  `#…-skip`. The `ref` travels in a hidden input because `phx-value-*`
  does not survive a submit, and the form is a plain `<form>` rather
  than `<.form>` — there is no changeset behind a question and a per-row
  form assign would have to survive every stream reset for nothing.
  `answer_question` submits, `skip_question` declines; both go through
  `Runtime.answer_question/3`. Once resolved the form is replaced by the
  recorded answers plus an Answered/Skipped/Cancelled chip — and only
  answers that reached the agent are listed, since a typed "Other"
  supersedes its selection before the row is written.

  Visual weight goes to the prose, not the machinery: a `:message` block
  is a bordered `surface` card with markdown at 13px, while a tool group
  sits directly on the page background in 11.5px mono. `tool_summary/1`
  reduces a call to `{label, detail}` — a path for a file tool, the
  description then the command for a shell call (never the command
  twice, since the harness titles the call with it) — and the collapsed
  group header reuses the same label.

  `handle_params/3` re-streams the feed with `reset: true` whenever the
  Agent tab becomes active. This is load-bearing, not defensive:
  LiveView prunes a stream's inserts after every render whether or not
  the container was on screen, so rows that arrived while another tab
  was open would otherwise be lost. `feed_blocks` in assigns is the
  server-side copy that makes the re-stream (and collapse state)
  possible.
- **Diff tab** — for repo targets with a worktree: `Git.diff/2` parsed
  by `CodeLead.Git.Diff` in `start_async`; collapsible reviewer
  findings (latest cycle) above the diff. Folder targets show the task
  folder listing + `output.md` preview.

  Files are collapsible panels keyed by path in the `diff_expanded`
  MapSet; entering the tab always resets to first-expanded. Jumping
  from the sidebar (`focus_file`) expands the target alone and
  `push_event`s `diff:scroll_to`, which the colocated `.ScrollToFile`
  hook turns into `scrollIntoView`. Pushed events are dispatched after
  the DOM patch, so the target is already expanded when the scroll runs.

  **`#diff-pane` is what scrolls, not the window.** The app shell is
  `h-dvh overflow-hidden` (see *Design language*), so `h-full` on the
  diff-tab root resolves against a real height and the pane's
  `overflow-y-auto` engages — which is also what makes `#diff-toolbar`'s
  `sticky top-0` and the per-file headers' `sticky top-0` live. The
  `.ScrollToFile` hook is indifferent either way: `scrollIntoView` moves
  whichever ancestors need moving, and its listeners sit on `document`,
  not on the pane.

  The diff refreshes live: an `{:agent_feed, _, row}` for which
  `AgentFeed.file_changing?/2` holds sets `diff_stale?` and arms a
  single 1.5s `Process.send_after` (`@diff_refresh_ms`). The timer is
  only armed while the Diff tab is active — off-tab, staleness just
  accumulates and `handle_params/3` picks it up on entry. `diff_stale?`
  clears when the load *starts*, so events arriving mid-diff re-arm on
  completion; a failed refresh keeps the diff already on screen and
  only logs. `#diff-refresh` forces one on demand.

  **Follow mode** (`following?`) is offered while `run_state` is
  `:executing`. `follow_path` tracks `data["locations"]` from tool-call
  rows (relativized against the worktree by `Format.project_path/2`,
  which the Agent tab shares) even while off, so engaging it lands
  immediately. A refresh re-focuses that file only when it differs
  from `follow_anchor` — re-anchoring every 1.5s would drag the viewport
  back through consecutive edits of one file.

  Control returns on `toggle_file`, `focus_file`, run end, tab entry, a
  click on the `#diff-following` chip, or `diff_unfollow` pushed by the
  hook. The hook reads user intent from `wheel`/`touchmove`/`keydown`
  rather than from `scroll`: those bubble, and a programmatic scroll
  never emits them, so they release follow instantly and need no timing
  guard. A capture-phase `scroll` listener is the backstop for scrollbar
  drags — that one is guarded by a 1s window so our own smooth scroll
  doesn't self-cancel. A `released` latch keeps one gesture to one push.
- **Terminal tab** — static placeholder (worktree path + dark pane);
  a real PTY is future work.

## Demo data

`priv/repo/seeds.exs` fabricates one failed-run, one in-review (two
verdicts + findings), and one done task via direct `Repo` writes
(clearly marked demo-only) so every column and tab renders after
`mix ecto.reset`.
