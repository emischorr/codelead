# Web UI (last updated: 2026-08-10)

The first two pages of the web layer: the Kanban board and the task
page, both LiveViews. Product spec §13 is the target; this note maps
what exists today.

## Routes

| Route | Module | Purpose |
|---|---|---|
| `GET /` | `PageController.home` | redirect to the first project's board (welcome page when no projects) |
| `/projects/:project_id/board` | `CodeLeadWeb.BoardLive` (`:index`) | the Kanban board |
| `/projects/:project_id/board/new` | `CodeLeadWeb.BoardLive` (`:new`) | new-task modal (patch-based) |
| `/projects/:project_id/tasks/:id` | `CodeLeadWeb.TaskLive` (`:show`) | task page; `?tab=task\|agent\|diff\|terminal` |

There is no auth/`current_scope` yet; the avatar is a placeholder.

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

The theme script in `root.html.heex` resolves "system" to a concrete
`data-theme=light|dark` (tracking `prefers-color-scheme`) and stamps
`data-theme-mode` for the toggle indicator.

## Component inventory

- `CodeLeadWeb.UIComponents` (imported in `html_helpers`): `badge`,
  `state_badge`, `agent_pill` (harness dot: claude_code `#D97757`,
  codex run, other accent), `pulse_dot`, `cost_stat`, `section_card`,
  `attention_banner`, `timeline_entry`, `tab_nav`, `kanban_column`,
  `task_card` (shell + column-specific `footer` slot), `chat_bubble`,
  `empty_state`, `fab`.
- `CodeLeadWeb.DiffComponents`: `file_list`, `file_diff` (dual
  line-number gutters, add/del row tints) over `CodeLead.Git.Diff`
  parser structs.
- `CodeLeadWeb.Layouts.app`: sidebar navigation — `:full` (232px,
  board) or `:rail` (64px icons, task page) on desktop, overlay drawer
  on mobile (`Layouts.sidebar_toggle` opens it). Takes `project`,
  `projects`, `attention_count`, `project_spend`,
  `budget_limit_cents` as assigns; no context calls in the layout.
- `CodeLeadWeb.Format`: `cents/1`, `tokens/1`, `cost_tokens/2`,
  `relative/1`, `time/1`. `CodeLeadWeb.FlashMessages` maps
  `Tasks.transition_error/0` reasons to flash text.

## BoardLive

Plain assigns (whole-board reload); `Tasks.subscribe_board/1` +
`{:board_changed, _, _}` → `load_board/1`, which batch-loads
`Costs.spend_by_task/1`, `Reviews.verdicts_by_task/1`,
`Tasks.commit_notes/1`, and queue positions from `Tasks.queued_tasks/0`.
No drag & drop — explicit Start (planning footer) and Archive (done
footer) actions. Mobile: segmented one-column switcher + FAB (DOM ids
prefixed `m-`). New-task modal validates work_type against
`Agents.eligible_executors/2`.

## TaskLive

Tab from `?tab=`, defaulting by state (planning→task, running→agent,
review→diff, done→task). Tab bodies are plain `Phoenix.Component`
modules under `task_live/` (`TaskTab`, `AgentTab`, `DiffTab`,
`TerminalTab`). All actions go through `CodeLead.Runtime`; errors map
to flashes.

- **Task tab** — attention banner (with Allow/Deny when a permission
  `ref` is stored), description/spec (edit form in planning via
  `planning_changeset`), planning-assistant chat
  (`Planning.send_message/3` is synchronous → `start_async`;
  assistant = first `llm_api` agent of the project), timeline
  (`Tasks.steps/1`), executor/reviewer selection (planning) or verdict
  list, per-run cost rows (`Costs.task_runs/1`).
- **Agent tab** — LiveView stream of live `{:task_event, _, event}`
  cards, seeded from task steps (events aren't persisted).
  `message_chunk`s accumulate in a `current_message` assign and flush
  into the stream on the next non-chunk event. Composer is disabled:
  the ACP driver's mid-run `send_message` is a stub.
- **Diff tab** — for repo targets with a worktree: `Git.diff/2` parsed
  by `CodeLead.Git.Diff` in `start_async`; collapsible reviewer
  findings (latest cycle) above the diff. Folder targets show the task
  folder listing + `output.md` preview.
- **Terminal tab** — static placeholder (worktree path + dark pane);
  a real PTY is future work.

## Demo data

`priv/repo/seeds.exs` fabricates one failed-run, one in-review (two
verdicts + findings), and one done task via direct `Repo` writes
(clearly marked demo-only) so every column and tab renders after
`mix ecto.reset`.
