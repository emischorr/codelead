# Navigation

The sidebar is the app's only navigation surface, and it is the same on
every authenticated page. This note records the contract it renders from,
the rules for what is enabled where, and why the project selection is
remembered the way it is.

(last updated: 2026-08-11)

## Two principles

**1. The sidebar owns identity and app-wide preferences; the page header
owns page context and page actions.**

Each page's 58px header is an action bar for the thing you are looking at —
its name, its live readouts, its buttons. Who you are signed in as and which
theme you prefer are true everywhere, so they live at the foot of the
sidebar, in `account_card/1`: avatar · theme switch · account · log out.
Nothing about the signed-in user appears in a page header.

`Layouts.auth/1` is the one exception, and only because it has no sidebar:
the setup wizard and the log-in pages keep a theme switch in their own
header.

**2. Navigation never disappears; project-derived readouts do.**

Every item keeps its place on every page. An item you cannot use right now
is rendered *deactivated* — same box, same position, muted, `aria-disabled`
— never removed, so the sidebar has one stable shape and nothing shifts
under the cursor when you move between the board and `/settings`.

The exceptions are the two readouts that carry project data rather than
navigation: the **budget tile** and the **attention pill**. Those are
hidden outside a project, because a stale number is worse than no number.

## `@nav`, the single contract

`CodeLeadWeb.NavContext` is an `on_mount` hook on
`live_session :require_authenticated_user` (after `UserAuth`, so
`@current_scope` exists). It assigns one map that the layout renders
from — LiveViews never assemble navigation themselves:

```elixir
%{
  projects: [%Project{}],     # Projects.list_projects/0
  project: %Project{} | nil,  # the selected project
  scope: :project | :general, # is this page inside a project?
  current: :dashboard | :board | :settings | :account | nil,
  attention_count: 0,
  spend: nil                  # %{cost_cents: _, tokens: _} | nil
}
```

- `scope` is `:project` when the mount params carry a `"project_id"` —
  i.e. on `/projects/:project_id/…` — and `:general` everywhere else. It
  is what decides whether the selector is a live disclosure or a label.
- `project` is picked out of the already-loaded `projects` list rather
  than re-queried. `BoardLive`/`TaskLive` keep their own
  `Projects.get_project!/1` so a bogus id still 404s; the hook stays
  raise-free.
- `current` is derived from `socket.view` by module prefix
  (`DashboardLive` → `:dashboard`, `BoardLive`/`TaskLive` → `:board`,
  `SettingsLive.*` → `:settings`, `UserLive.Settings` → `:account`).
  Adding a settings page needs no wiring.
- `attention_count` and `spend` start empty. The two pages that own live
  project stats push their already-loaded values in with
  `NavContext.put_stats/3` — the layout makes no context calls, and
  `NavContext` stays free of the costs/tasks domains. `DashboardLive`
  deliberately does not: it is org-wide, and both readouts are
  project-scoped.

Every page therefore renders the identical call, the task page adding only
the rail variant:

```heex
<Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
<Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope} sidebar={:rail}>
```

## Item table

Order is fixed across all three renderings: wordmark → project selector →
Dashboard · Board · Metrics · Settings → attention pill → spacer →
budget tile → account row.

The account row's middle slot holds the theme switch. On the no-projects
welcome page — which renders `account_card/1` inside `Layouts.auth`, whose
header already has one — pass `theme_toggle={false}` and the slot spells the
email out instead. In the sidebar the email lives on the avatar's `title`,
because the row has no width to spare.

| Item | Inside a project | On a general page | No project exists |
| --- | --- | --- | --- |
| Project selector | `<details>` disclosure, lists all projects | deactivated, names the remembered project | deactivated, "No project" |
| Dashboard | link | link, highlighted on `/` | link — it is org-wide and needs no project |
| Board | active, links to the project's board | links to the remembered project's board | deactivated |
| Metrics | deactivated (not built) | deactivated | deactivated |
| Settings | link | link, highlighted on `/settings/*` | link |
| Attention pill | shown when count > 0 | hidden | hidden |
| Budget tile | shown | hidden | hidden |
| Account row (avatar · theme · account · log out) | shown | shown | shown |

Switching projects is only offered from a project page: the selector is a
navigation control whose only destination is a board, and picking one from
inside `/settings/users` would silently mean "leave this page". So on
general pages it degrades to a label that answers *which project am I
coming back to*, which is the same question the Board link answers.

## Three renderings, one set of items

- **`:full`** — 232px, desktop default.
- **`:rail`** — 64px glyphs, used by the task page so the diff gets the
  width. It carries the *same items in the same order* (project glyph,
  Dashboard, Board, Metrics, Settings, attention badge, account), just
  collapsed. The
  one deliberate omission is the theme switch: a three-segment control does
  not survive 64px, and theme is a set-and-forget preference reachable from
  every other page.
- **Mobile drawer** — always rendered, `lg:hidden`, opened by
  `Layouts.sidebar_toggle` from each page's own header. It renders a
  second copy of `:full`, so its DOM ids are prefixed `m-` via
  `nav_id/2`. The rail's ids are prefixed `rail-`.

Stable ids for tests: `project-switcher`, `nav-dashboard`, `nav-board`,
`nav-settings`,
`attention-pill`, `budget-card`, `account-card`, plus the `m-` and
`rail-` variants and `nav-project-store`.

## Remembering the selected project

The selected project survives leaving the project. `Layouts.app` renders
one hidden element per page:

```heex
<div id="nav-project-store" phx-hook=".NavProject" data-project-id={@nav.project && @nav.project.id} hidden />
```

Its colocated hook mirrors the id into `localStorage["cl:project"]` while
you are inside a project, and — on a page where the server has no project
— pushes the stored value back as `"nav:restore_project"`. `NavContext`
handles that event through `attach_hook/4` on `:handle_event`, so no
LiveView needs a clause for it. A `nil` from the client (nothing stored
yet, e.g. a fresh browser deep-linking to `/settings`) falls back to the
first project.

General pages deliberately start with **no** project rather than guessing
the first one, so the selector never flashes the wrong name before the
client answers. `scope` stays `:general` through the restore, which is why
the budget tile does not appear.

Rejected alternatives:

- **Plug session / cookie.** A LiveView cannot write the Plug session, and
  the session handed to `mount` is the snapshot from the initial HTTP
  request — it goes stale the moment you live-navigate board → settings,
  which is exactly the case being solved.
- **LiveSocket connect params.** Fresh at connect, then frozen for the
  socket's lifetime. Same staleness on live navigation.
- **`?project=<id>` query param.** Correct, but has to be threaded through
  every settings-internal `navigate` and every post-submit redirect, and
  degrades silently the first time one is missed.

## Which pages get the sidebar

`Layouts.app` covers everything behind the auth gate: board, task,
`/settings/*`, `/users/settings`, and the dashboard at `/` — including
its no-projects state, which keeps the sidebar because
`/settings/projects/new` is somewhere to go. `Layouts.auth` — the
chromeless wordmark-and-centered-column shell — stays for the surfaces
that precede having an account at all: the setup wizard and the log-in
and confirmation pages.

## Adding a nav item

1. Add it to `sidebar_content/1` **and** `sidebar_rail/1` in
   `lib/code_lead_web/components/layouts.ex` — parity is the point.
2. Give it a `nav_id(@closable, "nav-<thing>")` id in the full sidebar and
   a `rail-<thing>` id in the rail.
3. If the item can be unusable, render the deactivated variant with
   `nav_class(:disabled)` / `rail_class(:disabled)` rather than dropping
   the element. An item that is always reachable (Dashboard, Settings)
   needs no disabled variant.
4. If it needs highlighting, extend `NavContext.section/1` and the
   `current` values; the LiveView itself stays untouched.
