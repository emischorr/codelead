# Web UI (last updated: 2026-08-11)

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
| `/settings/agents` | `CodeLeadWeb.SettingsLive.Agents` | org agents; `/new` and `/:id/edit` |
| `/settings/projects` | `CodeLeadWeb.SettingsLive.Projects` | list; `/new` |
| `/settings/projects/:id` | `CodeLeadWeb.SettingsLive.Project` (`:show`) | details, repositories, env store, default reviewers |
| `/setup` | `CodeLeadWeb.SetupLive` (`:index`) | first-run wizard, only while `setup_done` is false |
| `/users/*` | `CodeLeadWeb.UserLive.*` | log in, magic-link confirmation, account settings |

The project detail page also carries four patch-based sub-routes:
`/repositories/new`, `/repositories/:repository_id/edit`, `/env/new`
and `/env/:key/edit`. `/settings/projects/new` is declared **before**
`/settings/projects/:id` so the literal is not swallowed by the param.

All of the above except `/setup` and `/users/log-in` live in
`live_session :require_authenticated_user` behind both the setup gate and
the auth gate — see [`setup-and-auth.md`](setup-and-auth.md). All of them
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

Deferred here: project-scoped agents are not creatable or listed —
`Agent.changeset/2` does not cast `project_id`, so scope cannot be
changed through a form; moving an agent between scopes would need a
dedicated `move_agent/2`. The Organization tile is a placeholder because
`Accounts.update_organization/1` replaces `settings` wholesale and would
clobber `setup_done`; editing budgets there needs a merging setter first.

## Design language

Tokens live in `assets/css/app.css`: a raw palette on `:root` /
`:root[data-theme=dark]` (surface/border/text tiers, accent, run/warn/
ok, diff add/del, terminal), mapped through a Tailwind v4 `@theme`
block so utilities like `bg-surface`, `text-text2`, `border-border`
theme-switch without `dark:` prefixes. The default Tailwind palette is
dropped (`--color-*: initial`) to enforce token usage. Fonts are
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
- `CodeLeadWeb.Layouts.app`: sidebar navigation — `:full` (232px) or
  `:rail` (64px icons, task page) on desktop, overlay drawer on mobile
  (`Layouts.sidebar_toggle` opens it). Takes `flash`, `nav`,
  `current_scope` and optionally `sidebar`; no context calls in the
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
footer) actions. The planning footer's Start is a split control: the
clock button opens the shared `schedule_modal` and starts the run at a
chosen UTC time instead of now. A queued task with a future
`scheduled_at` shows `⏱ starts …` in place of the `⏸ queued · #N`
badge, derived from the task rather than from a persisted hold reason.
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
opening the shared `schedule_modal`) alongside **Start run**, and a
queued task whose start time has not arrived offers **Run now**
(`#action-run-now`, `Runtime.run_now/1`) beside Cancel run. A
`#scheduled-hint` badge next to the state badge shows the start time.

- **Task tab** — attention banner (with Allow/Deny when a permission
  `ref` is stored), description/spec (edit form in planning via
  `planning_changeset`), planning-assistant chat
  (`Planning.send_message/3` is synchronous → `start_async`;
  assistant = first `llm_api` agent of the project), timeline
  (`Tasks.steps/1` on a vertical rail, opened by a `timeline_start`
  node synthesized from `task.inserted_at` — no `:created` step row
  exists; every timestamp carries a UTC `title` that the `.LocalTime`
  colocated hook rewrites to the viewer's zone),
  executor/reviewer selection (planning) or verdict
  list, per-run cost/token/duration rows (`Costs.task_runs/1`, with the
  token split on hover).
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
  row has no `data["resolved"]`. Composer is disabled: the ACP driver's
  mid-run `send_message` is a stub.

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

  **The window is what scrolls, not `#diff-pane`.** `layouts.ex` opens
  with `min-h-screen` — a floor, not a height — and nothing below it is
  definite, so `h-full` on the diff-tab root resolves to `auto` and the
  pane's `overflow-y-auto` never engages. The hook is written to be
  indifferent to this: `scrollIntoView` moves whichever ancestors need
  moving, and its listeners sit on `document`, not on the pane. Same
  root cause makes `#diff-toolbar`'s `sticky top-0`, the per-file sticky
  headers, and the Agent tab's `sticky bottom-0` composer inert — fixing
  that means `h-dvh` + `overflow-hidden` on the app shell, which changes
  scrolling on every page.

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
  rows (relativized against the worktree) even while off, so engaging it
  lands immediately. A refresh re-focuses that file only when it differs
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
