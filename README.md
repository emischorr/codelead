# CodeLead

**A self-hosted, human-in-the-loop platform for building digital products with a team of AI agents.**

Where an AI coding assistant helps a *developer write code*, CodeLead helps a you *build a product* — planning, delegating, reviewing, and shipping work across coding and non-coding tasks.

You direct a virtual team of specialist agents from a Kanban board. They plan and execute. You decide what starts, what ships, and what goes back for another round.

> **Already paying for Claude Pro or Max?** CodeLead runs on your existing **Claude subscription** — no separate API billing required. **Claude Code is bundled** in the image; connect it with an OAuth token during setup and go. (An Anthropic API key, OpenAI, and local Ollama models work too.)

![The CodeLead board](docs/images/board.png)

---

## Why it exists

Autonomous agent runners optimize for getting out of your way. That works right up until the agent confidently builds the wrong thing and you find out three commits later. Or you more often busy cleaning up behind a herd of autonomous agents gone wild than actually building your product.

CodeLead is not built for vibe-coding. It's built for the practices that the software industry has spent decades converging on: a clear specification before work starts, a refinement pass to catch what the spec left out, and a review before anything ships. Those aren't extra steps bolted onto a fast agent loop — they're the workflow itself. The board's three working columns *are* that discipline, structural rather than left to habit.

CodeLead takes the opposite position from a "just let it run" tool: **humans own every handoff.** Agents plan and execute. You move the work between states. Automation that silently bypasses a human decision point is treated as a design failure, not a feature.

That constraint buys you a few things:

- **You stay close to the work without living in a terminal.** Task management is the primary surface. The diff and the agent transcript are there when you want them, one click away, not in your face by default.
- **Work is reviewable before it lands.** Every task gets its own git worktree on its own feature branch. Nothing touches your default branch until you approve it.
- **Cost is visible before it's a surprise.** Every run records tokens, money, and duration. Monthly budgets *hold* work instead of letting it run.
- **It's yours.** One instance, one organization. Your keys, your repositories, your machine. No telemetry, no cloud account, credentials encrypted at rest.

It's built for solo developers and freelancers acting as their own product owner, small teams and startups, and semi-technical builders with enough literacy to link a repo and review output. It is deliberately *not* built for large enterprises — heavy RBAC, SSO, and compliance workflows are out of scope.

---

## How it works

Four columns: **Planning → Running → Review → Done**.

There is no "Ready" column, and no drag & drop. Both are deliberate. In AI-driven work the human is the bottleneck, not worker availability, so the board models human↔agent handoffs rather than queues. And a board move here isn't the harmless reordering it is in a generic issue tracker — every edge fires automation and encodes a decision, so every edge is an explicit button that says what it will do.

<!-- ![A task in review](docs/images/review.png) -->

### Planning — your workbench

Write the task. Pick its **work type** (code, design, content, or file) and its **target** (a linked repository, or a standalone task folder). Optionally bring in a planning agent: a chat that sharpens your spec, or — for a real coding harness — a read-only **survey of your repository** that reports requirements gaps, contradictions with the existing code, and assumptions you left unstated. The planner never edits the task; you decide what makes it into the spec.

Then choose the **executor** that will do the work and **zero or more reviewers** that will critique it. Nothing runs automatically here.

### Running — the agent works

You press Start. CodeLead provisions the context — a git worktree on a fresh feature branch, or a task folder — and runs the agent, streaming its output to the board and the task page live.

The agent can stop and **ask you a question** mid-run, rendered as its own little form; the run waits, with no timeout, because waiting for the human is the point. If it tries to touch something outside its own workspace, you get an Allow/Deny prompt. If the run fails, the task stays put and raises an attention badge — a task is never silently stuck.

### Review — AI-assisted, human-decided

On entry, every reviewer you selected runs automatically and in parallel, read-only. Each produces its own findings plus an optional recommendation: *pass*, *concerns*, or *block*. You can point a security reviewer and an architecture reviewer at the same task and read both.

Verdicts are **advisory and gate nothing.** You weigh them and choose:

- **Approve** → Done.
- **Request changes** → back to Running with the same agent, worktree, branch, and session. Your feedback becomes the next prompt and the work accumulates.
- **Send back to Planning** → the worktree, branch, and session are discarded, because the spec it was built on is being rewritten.

### Done — ship it your way

Approve stays a single primary button whose label states what it will actually do: *Approve & open PR*, *Approve & merge*, *Approve & squash merge*, *Approve & hand over*, *Approve & commit artifact*. Projects set a default per target; any task can override it.

Merging is plain local git — `git merge` and `git push` — never a forge action. It works with GitHub, GitLab, a self-hosted forge, a bare SSH remote, even `file://`. CodeLead never presses someone else's Merge button, closes a PR, or gates on required checks.

---

## Features

- **Direct a team, not a chatbot.** Agents are reusable personas: a name, a work type, roles (execute and/or review), a model, and a system prompt. Build a frontend specialist, a security reviewer, a copy editor — then slot them into tasks.
- **Bring your own agents and models.** Full coding harnesses via the Agent Client Protocol — **Claude Code** and **Codex** — plus direct model calls to **Anthropic**, **OpenAI**, or a local **Ollama** for cheap reviewers, planners, and short-form content. Not every agent needs to be a coding harness.
- **Not just code.** Code, design, content, and file work each get the review surface that suits them: a diff, a rendered HTML preview, rendered Markdown, or a file listing. Content and design tasks can target a repository and go through the same branch-and-PR flow as code.
- **Isolated by construction.** One task, one worktree, one feature branch. Non-repo work gets its own task folder. Cancel a run and the worktree stays for inspection.
- **Parallel review, advisory only.** Several reviewers with different focuses on the same artifact. A reviewer that crashes or times out never blocks your cycle.
- **Plan before you burn tokens.** A repo-aware survey reads your existing code and tells you what your spec leaves out — before an executor spends an hour building the wrong thing.
- **Know what it costs.** Per-run tokens (prompt, completion, cached, reasoning), money, and duration. Monthly budgets at project and organization level that hold a task rather than starting it and lift by themselves on the 1st. Subscription-based providers are shown as estimates, local models as free — the number never pretends to a precision it doesn't have.
- **Watch it work, or don't.** Live agent transcript, live diff with a follow mode that tracks the file the agent is editing and lets go the moment you scroll yourself.
- **Secrets stay secret.** Provider credentials and per-project environment variables are encrypted at rest and write-only through the UI — you can replace a stored value, never read it back. Forge tokens reach git through a per-invocation credential helper, so they never land in `.git/config`, in argv, or on disk.
- **Triage at a glance.** A dashboard across every project: what needs approval, what failed, what's running, what stalled, throughput and lead time, and where the money went.

---

## Getting started

You need Docker and about five minutes. CodeLead ships as a published image — `ghcr.io/emischorr/codelead:latest`, multi-arch for amd64 and arm64 — plus a PostgreSQL database. A ready made compose stack lives in [`deployment/`](deployment/).

**1. Copy the `deployment/` folder** — `docker-compose.yml`, `.env.example`, and `init-app-db.sh` — into a directory on the host.

**2. Create `.env` from the template** with `cp .env.example .env`, and fill it in. All four values are required:

```bash
POSTGRES_PW="…"       # any strong password — the Postgres superuser
APP_DB_PW="…"         # any strong password — the app's own `codelead` role
SECRET_KEY_BASE="…"   # openssl rand -base64 48
ENCRYPTION_KEY="…"    # openssl rand -base64 32
```

> `ENCRYPTION_KEY` must decode to **exactly 32 bytes** — use `openssl rand -base64 32`, not a hex string. It's the key for everything encrypted at rest: provider credentials and project secrets. **Back it up.** Without it those rows are unreadable, and a fresh key does not recover them.

`APP_DB_PW` is used twice: `init-app-db.sh` runs once at first database init to create a non-superuser `codelead` role and database, and the app connects with it.

**3. Start it:**

```bash
docker compose up -d
```

That's the whole thing. The one-shot `migrate` service runs the migrations first and the app waits for it to finish before booting.

Then open **http://localhost:4000**, which lands on the setup wizard.

### Putting it on a real hostname

CodeLead serves **plain HTTP** and does nothing about TLS — no redirect, no HSTS. Terminating TLS, and choosing what terminates it, is yours: most users already run a reverse proxy or may have opinions about which. Put nginx, Caddy, Traefik, or whatever you already operate in front of port 4000.

Two things to set, whichever you pick:

- **`PHX_HOST` must match the hostname in the browser's address bar.** It feeds Phoenix's origin check, so getting it wrong means the page loads and then goes dead — LiveView never connects.
- **`SCHEME`** — `http` for direct access, `https` behind a TLS-terminating proxy. It defaults to `http` and only affects the absolute URLs in login and invite links — but a wrong one points them at an address that doesn't answer.

Behind a proxy on the standard port that is all: `URL_PORT` defaults to 443 for `https` and 80 for `http`, so links come out without a port suffix. Set **`URL_PORT`** only when the address people actually type carries a port — the shipped compose stack sets `URL_PORT: "4000"` because it is reached directly on 4000. It is independent of `PORT`, which moves the listen port and nothing else.

One instance can answer at several addresses — say `https://codelead.example.com` through the proxy and `http://192.168.1.50:4000` straight from the LAN. `PHX_HOST` stays the canonical one that generated links use; list the others in **`ALLOWED_HOSTS`** (comma-separated) so the origin check lets them open a LiveView connection too.

Full recipes, proxy configuration snippets, upgrades, and backups are in [`docs/deployment.md`](docs/deployment.md).

### Configuration

| Variable | Required | Default | What it's for |
|---|---|---|---|
| `DATABASE_URL` | yes | — | `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | yes | — | Signs and encrypts cookies. `openssl rand -base64 48` |
| `ENCRYPTION_KEY` | yes | — | Encrypts stored credentials. Base64-encoded 32 bytes: `openssl rand -base64 32` |
| `PHX_HOST` | yes in practice | `example.com` | The canonical hostname — what generated links use. Also allowed by the origin check; a mismatch breaks LiveView |
| `ALLOWED_HOSTS` | no | — | Extra addresses the app answers at, comma-separated. Bare host = any scheme/port, full origin = exact match, `*` = disable the origin check |
| `SCHEME` | recommended | `http` | Scheme for generated links. Set to `https` when a proxy terminates TLS |
| `PORT` | no | `4000` | The port the app listens on. Nothing else |
| `URL_PORT` | no | `443` for https, `80` for http | The port in generated links. Set it only when the app is reached directly on a non-standard port |
| `WORKSPACE_ROOT` | no | `/data/workspace` | Where clones and worktrees live |
| `MAX_CONCURRENT_RUNS` | no | `3` | How many agents may run at once |
| `LICENSE_KEY` | no | — | Signed license key. Absent means the community tier, which grants everything except container execution |
| `POOL_SIZE` | no | `10` | Database connection pool size |
| `ECTO_IPV6` | no | — | `true` to reach the database over IPv6 |
| `DNS_CLUSTER_QUERY` | no | — | DNS query for clustering (unused in a single-node deployment) |

### First run

A fresh instance sends every URL to a **setup wizard** at `/setup`, five steps:

1. **Admin** — organization name, your email, a password. You end up logged in.
2. **Provider** — a model backend: Anthropic (API key or subscription OAuth token), OpenAI, or Ollama.
3. **Project** *(skippable)* — name, repository, git URL, default branch, and an optional access token, verified against the remote right there so a bad token surfaces now instead of at your first run.
4. **Agent** *(skippable)* — your first worker persona.
5. **Finish.**

Each step commits as you submit it, so reloading resumes where you left off.

**Self-signup is closed after that.** Every later account is created from Settings → Users, by magic-link invite or with a password.

### What you'll need

- **A git remote you can push to**, and a token for it: GitHub fine-grained PATs need *Contents: Read and write*, GitLab needs `write_repository`. Store it per project in the encrypted environment store — the same token handles git transport *and* opens the PR at Done. SSH remotes ignore it and use the server's key instead.
- **A model provider credential** for at least one provider.
- **The Claude Code harness is bundled** in the image. **Codex is bring-your-own** — the `codex` binary must be on the PATH of the process running CodeLead. A missing harness fails the run at dispatch with a message naming the executable, before anything is cloned.

---

## Project status

Early, and honest about it. So issues are welcome. Eat your own dog food: I use this (and the predecessor of it) roughly since the start of 2026 to manage almost all of my current projects (~10 - libraries, web apps, websites and small businesses).

**Currently missing. Coming up next:**

- **No authorization.** A user's role is stored and displayed but never enforced — every signed-in user can reach every settings page. Only invite people you'd trust as an admin.
- **Email is off by default.** Without `SMTP_HOST` there is no mail transport, and the flows that need one (magic-link login, magic-link invites) stay hidden — create users with a password from Settings → Users. Set `SMTP_HOST` to enable them. The self-service email-change page is the exception: it still claims to have sent a confirmation link.
- No profile page, and no organization/instance settings (the tile is a placeholder).
- No metrics page — the sidebar item is deactivated.
- The in-task terminal shows the worktree path but isn't a real terminal yet.
- You can't message an agent mid-run; ask-and-answer works, free-form chat doesn't.
- Project-scoped agents exist in the model but aren't creatable through the UI.

**Planned:** sub-tasks and epics, cost and usage dashboards, a review walkthrough that explains a diff step by step, agent memory that learns your preferences, container-based executors with resource caps, and queuing that waits for a subscription's token window to reset.

**Out of scope on purpose:** releasing (tags, changelogs, deploy pipelines), forge-side automation (auto-merge, closing PRs, gating on required checks), and enterprise features (fine-grained RBAC, SSO, several organizations per deployment).

---

## Developing locally

Toolchain is pinned in `.tool-versions` — Erlang 28.5.0.5, Elixir 1.20.3-otp-28.

```bash
docker compose up -d          # Postgres 16 on :5432
mix setup                     # deps, database, seeds, assets
mix phx.server                # http://localhost:4000
```

Sign in with `admin@example.com` / `codelead-dev-password`. The seeds create a demo project backed by a local bare git repository, so the full clone → branch → review → merge flow works offline, and they mark setup as done — to exercise the wizard, create and migrate a database without running the seeds.

```bash
mix test                      # creates and migrates the test database first
mix precommit                 # compile --warnings-as-errors + format + test
mix ecto.reset                # drop, recreate, wipe workspace state, reseed
```

Architecture and internals live in [`docs/INDEX.md`](docs/INDEX.md). The target state — what's being built toward, and why — is in [`codelead-product-spec.md`](codelead-product-spec.md) and [`codelead-architecture-spec.md`](codelead-architecture-spec.md).

---

## License

[Elastic License 2.0](LICENSE.txt). Free to use, modify, and self-host, including commercially. Two limitations: you may not offer CodeLead to third parties as a hosted or managed service, and you may not circumvent the license key functionality.

One feature is declared paid: running a task inside a container (`Execution: Container`). Everything else — the board, the runtime, the agents, reviews, the whole web UI — is free, so an instance with no `LICENSE_KEY` runs as the community tier and is fully usable. See [`docs/licensing.md`](docs/licensing.md).


Copyright (c) 2026 Enrico Mischorr