# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Companion documents

Read these before non-trivial work — they carry most of the context that isn't in the code:

- **`codelead-product-spec.md`** / **`codelead-architecture-spec.md`** — the MVP target state (product behavior and data model/abstractions respectively). **These specs are the source of truth for what to build**, not the current code.

## Documentation

Detailed docs live in `docs/` — start at `docs/INDEX.md`, which maps every
file (architecture overview, task workflow, agent adapters/communication) so you only load what you need.
**Keep the docs current:**
when a session changes architecture, workflow rules, or adapter behavior,
update the affected doc and `docs/INDEX.md` in the same session.

- **`/docs/INDEX.md`** - This is a index file of the documentation of the repo
- **`/docs/adr/*`** - ADRs of the project - read only. Never update existing ADRs

## Project state

The domain layer, the runtime, and the first web surfaces exist: schemas and migrations for the full model, the `Tasks`/`Projects`/`Agents`/`Reviews`/`Costs`/`Planning` contexts, the ACP driver + scheduler + task runner, the board and task LiveViews, `phx.gen.auth` with a `/setup` gate (see `docs/setup-and-auth.md`), and the `/settings` area — users, providers, org agents and projects, each with list/create/edit and guarded deletes (see `docs/web-ui.md`). Self-signup is closed: the wizard creates the first admin and every later account comes from `/settings/users`. Still missing: the Profile page, organization/instance settings (the overview tile is a placeholder), and most of the "designed-for-now, built later" items. There is no authorization anywhere — `users.role` is stored and displayed but never enforced. Derive the delta from the specs rather than assuming a surface exists.

The app is deployed: a published image (`ghcr.io/emischorr/codelead`) and the compose stack in `deployment/` run a real instance — see `docs/deployment.md`. **Schema changes therefore ship as new forward migrations**; folding a change into an existing migration or assuming a drop-and-recreate is no longer acceptable. `mix ecto.reset` stays a local-dev convenience, not the upgrade path.

## Commands

```bash
mix setup                     # deps + ecto.create/migrate/seed + assets setup & build
docker compose up -d          # Postgres 16 on :5432 (postgres/postgres)
mix phx.server                # dev server on localhost:4000
iex -S mix phx.server         # same, with a shell

mix test                      # auto-creates & migrates the test DB first (alias)
mix test test/path/file_test.exs        # single file
mix test test/path/file_test.exs:42     # single test by line

mix precommit                 # compile --warnings-as-errors + deps.unlock --unused + format + test
mix credo                     # not part of precommit — run separately
mix ecto.reset                # wipe per-task workspace state + drop + create + migrate + seed; refuses while runs are live (mix code_lead.workspace.clean --force to override)
```

`mix precommit` runs in `MIX_ENV=test` (set via `preferred_envs`). Run it when you're done with a change and fix anything it reports.

Note that `docker-compose.yml` only declares `code_lead_dev`; the test database (`code_lead_test`) is created by the `mix test` alias against the same server.

Toolchain is pinned in `.tool-versions` (Erlang 27.3.4.14, Elixir 1.18.4-otp-27). Secrets for local dev live in `.envrc` (gitignored, direnv).

## Architecture to build toward

CodeLead is a self-hosted, human-in-the-loop platform where a product owner directs a team of AI agents. The organizing principle: **humans own every handoff between workflow states.** Automation that bypasses a human decision point is a design failure. The single exception is Running→Review on success, which is a completion signal rather than a decision.

**Workflow.** A Kanban board of four columns — Planning → Running → Review → Done — where `tasks.state` is the column and `tasks.run_state` (`:idle`/`:queued`/`:dispatched`/`:executing`/`:failed`) tracks execution inside Running. Every transition, its trigger, actor, and side effects are tabulated in the architecture spec §4; consult it rather than inferring. The subtlety worth internalizing: *request changes* (Review→Running) preserves the worktree, branch, and ACP session so commits accumulate, while *send back to Planning* discards all three because the spec it was built on is being rewritten.

That table is **data, not code**: the machine dispatches on a stage's `stage_type` (`:plan`/`:execute`/`:review`/`:finalize`/`:custom`) and on per-edge policies (`trigger`, `context_policy`, `worktree_policy`) held in a single declarative `%CodeLead.Workflow{}`, never on column identity — see spec §4.1 and `docs/task-workflow.md`. Add a transition by editing the definition, not by adding a branch.

**Two independent axes** describe a task. `work_type` (`code`/`design`/`content`/`file`) filters which agents are selectable and picks the review renderer; `target` (`:repo`/`:folder`) decides where work lands and what Done does. They are deliberately decoupled — a `content` task can target a repo and go through the branch/PR flow.

**Extension points are behaviours, each with exactly one MVP implementation:**

- `CodeLead.AgentDriver` — `Acp` (drives a coding harness like Claude Code/Codex over the Agent Client Protocol: JSON-RPC 2.0 over stdio, bridged via Erlang Ports) and `LlmApi` (a single completion call, used for reviews and short content). Later: nothing new; the driver is independent of the executor.
- `CodeLead.Executor` — `LocalSubprocess` (default) and `DockerContainer` (per-task opt-in: repo-target tasks with `execution_env: :container` run in a sibling container from the repository's declared `image_ref`; no fallback image, ADR-0004). Provisions the worktree or task folder, spawns processes, tears down. `spawn/3` runs the agent *inside* the provisioned context (Model A, ADR-0003).
- `CodeLead.Scheduler` — `PassThrough` (MVP: admit unless over budget, dispatch immediately) and `Windowed` (later: hold for subscription token-window resets). Bound to the task's *provider connection*, not global.

Reviewers are deliberately **not** a separate abstraction — they are ordinary `agents` rows with `:review` in `roles`, run through the same `AgentDriver` in a read-only posture, fanned out concurrently on Review entry. Their verdicts are advisory and gate nothing.

**Runtime shape.** One GenServer per active task run supervises the driver/port, normalizes the event stream, updates the task, and broadcasts over Phoenix.PubSub; LiveViews subscribe to board and task topics. `attention` is a field on the task, not per-user notification fan-out. Derive task state from protocol events, never from agent self-report. Prefer existing OTP patterns (GenServer, PubSub, Ports, Oban) over new abstractions.

**Gating.** Every browser request passes two gates in order: `CodeLeadWeb.SetupGate` (redirects to `/setup` until `organizations.settings["setup_done"]` is true) and `CodeLeadWeb.UserAuth` (redirects to `/users/log-in`). Each is both a plug *and* an `on_mount` hook, because live navigation inside a `live_session` skips router pipelines. Read `docs/setup-and-auth.md` before touching the router, `CodeLead.Accounts`, or the auth LiveViews.

**Background jobs:** Oban is installed and supervised — queues `rollups` (nightly cost rollups) and `dispatch` (scheduled-run wake-ups). Cloak.Ecto has landed — `CodeLead.Vault` encrypts provider credentials and the project env store, keyed by an instance `ENCRYPTION_KEY`. The project env store is also where git/forge access tokens live (`GITHUB_TOKEN`/`GITLAB_TOKEN`); see `docs/configuration.md`.

**Licensing.** The project is Elastic License 2.0, and `CodeLead.License` is the entitlement seam ELv2's key clause refers to. **It gates nothing** — `@gated_features` is empty, so `feature_enabled?/1` is always true and every instance runs as `:community`. That is deliberate, not unfinished. Entitlements come from an offline Ed25519-signed `LICENSE_KEY` resolved once at boot, are instance-scoped like the singleton `organization`, and fail *open* to community on any problem. Making a feature paid means adding its atom to `@gated_features` and checking `feature_enabled?/1` at the call site **and** in the authoritative server-side action — never a UI-only check. Read `docs/licensing.md` before touching any of it; note that unlike `Executor`/`Scheduler` the source is deliberately **not** config-swappable.

`:req` is the HTTP client — do not add HTTPoison, Tesla, or `:httpc`.

## Further instructions

Do NOT commit yourself.

@AGENTS.md
@CODING_GUIDE.md