# Project readiness (last updated: 2026-08-27)

What a repository has to do to be pleasant to work on **with** CodeLead. This
is the project owner's half; the operator's half — DNS, TLS, the reverse
proxy, the instance's own environment — is in
[`deployment.md`](deployment.md) and [`configuration.md`](configuration.md),
and nothing here needs it.

Nothing below is required to *run* tasks. A repository with none of it still
gets planning, execution, diff review and a PR. What it buys is the Review
tab's live preview, and — separately — the option of running tasks inside the
repo's own toolchain instead of the shared image.

Drop-in templates for both are in
[`../templates/project-readiness/`](../templates/project-readiness): a snippet
for the project's `CLAUDE.md` / `AGENTS.md`, and a Claude Skill that applies
the whole checklist in one pass.

## What CodeLead hands your project

Exactly three environment variables, injected into the preview command **and**
into every Terminal session — nothing else, and nothing at all when the
repository declares no preview port:

| Variable | Under the default path gateway | Under [subdomain previews](configuration.md#subdomain-previews-preview_domain) |
|---|---|---|
| `PREVIEW_PORT` | the repository's declared port, e.g. `4001` | same |
| `PREVIEW_BASE_PATH` | `/preview/<task_id>` — **no trailing slash** | `""` |
| `PREVIEW_ORIGIN` | the instance's own origin | `https://task-<id>.<preview domain>` |

The port is **declared, never detected**: a human sets it on the repository
(Settings → Projects → repository), it must be unique across the instance, and
it cannot be CodeLead's own port. That is also the port a relay forwards for
container tasks, so a server listening anywhere else resolves to nothing.

Operator-side variables (`PREVIEW_DOMAIN`, `PREVIEW_PUBLISH_IP`, …) are
scrubbed from the spawned process. Your project never sees them, and must
never key off them.

## The four rules

Each is a no-op when the variables are unset, so none of them changes ordinary
local development.

**Bind `$PREVIEW_PORT`, with the project's usual port as the fallback.**
Hardcoding a port is the single most common reason a preview never comes up.
When it fails, CodeLead's diagnostic page says so in as many words: *the
command names neither `$PREVIEW_PORT` nor `<port>`, so the server is probably
listening on its framework's default port*.

**Bind `0.0.0.0`, not `127.0.0.1`.** For a container task the proxy arrives
over the container's network via a relay sidecar, and a connection from the
network cannot reach a socket on the container's own loopback. A local task is
unaffected, which is exactly why this one gets discovered late.

**Honor `$PREVIEW_BASE_PATH`.** Under the default gateway the app is served
under a prefix it does not know about, and the proxy **never rewrites response
bodies** — that is a decision, not a gap ([ADR-0008](adr/0008-preview-and-terminal.md),
upheld by [ADR-0011](adr/0011-new-tab-preview-and-subdomain-gateway.md)), and
[`preview-gateways.md`](preview-gateways.md) explains why the alternative is
worse. Root-relative `Location` headers are fixed up and cookies are
namespaced, but every URL in a body is the app's own problem. Per-stack
recipes are in [`configuration.md`](configuration.md#preview-base-path).

**Never write a root-absolute URL by hand.** Honoring the base path configures
the *router*; anything outside the router still emits `/…` and lands on
CodeLead instead of your app. Three escapes account for nearly all of it —
hardcoded websocket paths, `url("/…")` in CSS, and literal `href="/"` — and
[*When the preview tab flickers*](configuration.md#when-the-preview-tab-flickers)
covers each with the fix. Read it before debugging a preview that reloads
itself: a hardcoded socket path does not merely lose its connection, it puts
the page into a permanent reload loop, and the diagnostic CodeLead serves in
its place is a diagnostic, not a fix.

## Making the devcontainer work for agents too

A repository that declares Devcontainer execution runs its tasks inside the
environment its own `.devcontainer` describes, provisioned by the official
devcontainer CLI — so whatever already works in VS Code or Codespaces works
here ([ADR-0009](adr/0009-devcontainer-execution.md)). Container execution is
the one licensed feature, so an instance needs a `LICENSE_KEY` granting
`:container_execution_env` to select it; see [`licensing.md`](licensing.md).
There is deliberately no fallback: an enabled repository with no discoverable
config fails the run visibly.

**Hard requirements.**

- A config at a spec-discoverable path — `.devcontainer/devcontainer.json`,
  `.devcontainer.json`, or `.devcontainer/<folder>/devcontainer.json` — or an
  explicit path set on the repository.
- Everything the config references resolves against the **host** daemon:
  images, `build.dockerfile`, `dockerComposeFile`, bind sources.
- A POSIX `sh` in the primary container. Every exec needs it, and so does the
  libc probe that runs at each spawn.
- A glibc (Debian bookworm or newer) or musl (Alpine) base — the harness
  flavor is chosen from that probe ([ADR-0006](adr/0006-harness-libc-flavors.md)).
- `git` on `PATH`, and an exec user that can write the worktree.

**Strongly recommended — the three at the top are the ones that actually bite.**

- **Keep toolchain and package-manager state out of `$HOME`.** CodeLead
  overrides `HOME` per task (each task gets its own agent home on the
  workspace), so anything a feature or image installed under `~` — nvm,
  rustup, pyenv, cargo, hex — is simply not there for an agent. Point them at
  `/opt/…`. This repo's own `.devcontainer/Dockerfile` sets
  `MIX_HOME`/`HEX_HOME` for exactly this reason.
- **Keep build output off the shared workspace mount** (`MIX_BUILD_ROOT`,
  cargo's `target-dir`, …). The worktree is bind-shared with the host, so
  host-built and Linux-built artifacts otherwise poison each other.
- **Install dependencies in the image, keyed on the lockfile — not in the
  hook.** Every task is its own worktree and its own container, so a
  lifecycle hook that installs from scratch pays minutes and a network
  round-trip *per task*, and an agent that finds nothing installed will
  install it again on your token budget. The host's Docker layer cache is
  shared by every task container, so `COPY` the manifest and lockfile alone
  and install in a `RUN` above the source: the layer is built once per
  lockfile change and reused by every task afterwards. This repo's own
  `.devcontainer/Dockerfile` is the worked example — `mix.exs`/`mix.lock` +
  `config/`, then `deps.get` + `deps.compile` into `MIX_DEPS_PATH` and
  `MIX_BUILD_ROOT`. Then say so in the project's `CLAUDE.md`/`AGENTS.md`, or
  agents will keep re-running setup out of habit.
- Set `remoteUser` (or `containerUser`). It is read from the container's
  `devcontainer.metadata` label and passed to every exec; without it agents run
  as the image default — usually root — and root-owned files in the worktree
  surface later as teardown leftovers.
- Leave the hooks reconciling the *delta*: `postCreateCommand` for what the
  image could not bake (a dependency install against the branch's lockfile,
  seeds, an initial build), `postStartCommand` for migrations — it re-runs on
  every start, so it also catches migrations the branch gained mid-task and a
  container restarted after the instance was. `postCreateCommand` runs once
  per container *creation*, so anything only there is missed by a restart —
  and the CLI marks it done *before* running it, so one that fails is never
  retried: the run fails, the container survives, and every later `up`
  succeeds without it. That is the failure mode a `postStartCommand` quietly
  repairs. A failing hook fails the run, which is right for
  `postCreateCommand` and wrong for `postStartCommand` — end that one with
  `|| echo …` unless
  you want a bad migration to lock you out of the Terminal you would fix it
  from. The preview command must be a single process.
- Bring companion services in through `dockerComposeFile`. The executor never
  invents a services model of its own.
- Put `PATH` additions in `/etc/profile.d/*.sh` — the preview command runs
  under a login shell.
- Install `script` (util-linux) for a real PTY in the Terminal tab; without it
  the terminal degrades to a plain pipe.
- Cap resources with `runArgs` / `hostRequirements` if you need to. There is
  no CodeLead-side knob.

The first three are the ones that get skipped, and a devcontainer written for
VS Code has no reason to have them — so check rather than assume. For a Phoenix
project, from the repo root:

```bash
grep -rn  '"remoteUser"\|"containerUser"'    .devcontainer/ || echo 'GAP: no remoteUser'
grep -rn  'MIX_HOME=\|HEX_HOME='             .devcontainer/ || echo 'GAP: toolchain state left in $HOME'
grep -rn  'MIX_BUILD_ROOT=\|MIX_DEPS_PATH='  .devcontainer/ || echo 'GAP: build output on the workspace mount'
grep -rEn '^[[:space:]]*COPY.*mix\.lock'     .devcontainer/ || echo 'GAP: no lockfile-keyed dep layer'
```

The trailing `=` and the anchored `COPY` are deliberate: without them a comment
that merely names the variable passes the check. A grep hit still only proves
the Dockerfile *mentions* it — `docker exec <id> printenv` against a built
container is the check that proves it reaches an exec.

Substitute the equivalents for other stacks — `GEM_HOME`/`BUNDLE_PATH` +
`Gemfile.lock`, `CARGO_HOME`/`RUSTUP_HOME`/`CARGO_TARGET_DIR` + `Cargo.lock`,
`NPM_CONFIG_PREFIX`/`PNPM_HOME` + the npm lockfile. The
[`codelead-ready` skill](../templates/project-readiness/skills/codelead-ready)
runs this audit for you and fixes what it finds.

**Ignored — do not configure these for CodeLead's sake.** This is the list
that saves the most time:

| Key | Why it does nothing here |
|---|---|
| `forwardPorts`, `appPort`, `portsAttributes` | Never read. Preview reachability is handled by a relay sidecar on CodeLead's side. |
| `workspaceFolder` | Honored by the CLI for its own mount and lifecycle hooks, but execs run at the host-coincident worktree path instead. Never "fix" paths to match it. |
| `overrideCommand` / an idle entrypoint | The CLI owns keepalive. |
| node, or anything harness-related | The harness ships its own staged runtime on the workspace. |

Leave existing values alone — they serve the VS Code path, which keeps
working.

One durability rule worth internalizing: anything written **outside** the
workspace mount dies with the environment, and teardown takes a compose
project down with `--volumes`. Durable state belongs in the worktree, the
agent home, or somewhere you are content to lose on the next teardown.

## What no project change can fix

Under the default path gateway the preview shares CodeLead's origin, so cookie
names are namespaced per task. Frameworks using **double-submit CSRF** —
Django, Laravel, Angular — read the cookie by name in client JS, find the
namespaced one, and send no header, so **AJAX writes get 403**. Server-rendered
form posts are unaffected, and Phoenix is unaffected entirely.

There is no repo-side workaround. The fix is the operator enabling
[subdomain previews](configuration.md#subdomain-previews-preview_domain),
which gives each task a real origin and makes this section moot along with the
whole base-path contract.

Also reserved: the cookie name **`_clp_session`**, used by the subdomain
gateway's auth handshake. A previewed app must not use it.

## The worked example

This repository is its own. `config/dev.exs` reads `PREVIEW_BASE_PATH` into
`url: [path: …]` and flips the bind to `0.0.0.0` when the devcontainer sets
`DEVCONTAINER`; `.devcontainer/` carries the compose services, the `remoteUser`,
the out-of-`$HOME` toolchain env, the lockfile-keyed dep prewarm, and hooks
that only reconcile the delta. Point a CodeLead instance at this repo
with Container execution enabled and it dogfoods the whole contract —
[*Container execution in dev*](configuration.md#container-execution-in-dev)
walks through it.
