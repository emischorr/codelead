# ADR-0014: Flat two-layer authorization — instance role + ordered project role, single Policy module

Date: 2026-08-29
Status: accepted

## Context

CodeLead started single-user: `users.role` was stored and displayed but
nothing read it — every signed-in user could reach every settings page
and act on every task. The next users are a second person on the same
instance and small teams needing several people with access to
*different* projects, plus stakeholders who should file ideas without
being able to spend money or approve work.

## Decision

Two flat layers, one policy seam:

- **Instance role** stays `users.role` (`admin | member`). Admins own
  instance administration (users, providers, organization, org agents,
  license) and **bypass project membership**: they act as `:maintainer`
  on every project. The last admin can be neither demoted nor deleted,
  mirroring the existing last-user guard.
- **Project role** is a new `project_memberships` table — one row per
  (project, user) with an **ordered** role, `reporter < member <
  maintainer`. Reporters view the project, create tasks, and edit/
  delete/refine their **own** tasks while in Planning (ownership =
  `tasks.created_by_id`); members work every human gate; maintainers
  also manage project settings (except budgets, which are admin-only)
  and members. Project creation stays open to every signed-in user; the
  creator becomes maintainer in the same transaction.

`CodeLead.Accounts.Policy` is the single seam — `can?/3` and
`authorize/3` over one flat action list, comparing project roles through
an explicit rank map (the `@severity_order` convention), so a future
role slots in without touching the checks. It plays the role
`@gated_features` plays in `CodeLead.License`. Contexts authorize at the
boundary and return `{:error, :unauthorized}` alongside their existing
error shapes; reads are scoped at the query (an optional `project_ids`
filter on the aggregates, `nil` = unrestricted); the UI only mirrors
what the context would refuse. The `Scope` struct carries the
memberships map, loaded once per request/mount.

Org default project budgets (`default_project_budget_limit_*` on the
organization) are **copied onto the project at creation**, never
inherited live — the number on the project is the number that applies.
Human transitions record the acting user (username in the step's
`executor_name`, id in `task_steps.user_id`); there is no audit UI.

The forward migrations backfill every existing user as maintainer of
every existing project (existing instances have a handful of fully
trusted users; admins bypass anyway) and stamp existing tasks'
`created_by_id` with the first admin.

## Alternatives rejected

- **A `viewer` role** below reporter — no identified user; the ordered
  enum leaves room for it without touching the checks.
- **Permission sets / fine-grained grants** — a policy matrix nobody
  administers at this scale; the flat action list keeps every rule
  readable in one module.
- **Teams/groups** — indirection with no second customer; memberships
  are per-user.
- **Per-task ACLs** — the task-level nuance that exists (reporter
  own-task) is one rule in Policy, not a table.
- **Admin-only project creation** — would funnel every idea through an
  operator; if ever wanted it is an organization setting, not a role
  change.
- **Live inheritance of the org default budget** — copy-at-creation is
  legible and keeps `Costs.check_budget/1` untouched.

## Consequences

- Authorization has exactly one home; adding a rule means adding an
  action atom and a Policy clause, plus `authorize/3` at the context
  boundary it protects.
- Membership/role writes must go through the `Accounts` CRUD — they
  broadcast `{:scope_changed, user_id}`, which is how open LiveViews
  follow along (see `docs/navigation.md`).
- The repository/env-store functions still take a bare `project_id`,
  protected by the maintainer gate on the settings page rather than at
  the context boundary — parked on the roadmap.
