# Configuration (last updated: 2026-08-16)

All environment variables are read in `config/runtime.exs` and accessed in
application code via `Application.get_env(:code_lead, ...)` — never
`System.get_env/1` outside of config files (see CODING_GUIDE.md).

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ENCRYPTION_KEY` | fixed dev/test key; **required in prod** | Base64-encoded 32-byte key for `CodeLead.Vault` (Cloak AES-GCM). Encrypts provider credentials and the project env store. Generate: `32 \|> :crypto.strong_rand_bytes() \|> Base.encode64()`, or `openssl rand -base64 32`. Anything that does not decode to exactly 32 bytes fails at boot. |
| `WORKSPACE_ROOT` | `<repo>/workspace` (dev/prod) | Root for CodeLead-managed working state: base clones, per-task git worktrees, task folders. Gitignored. **Ignored in `:test`** — the test suite wipes its workspace root before running, and an agent's `mix test` inside a task worktree inherits the instance's env, so honoring this var in test once wiped a deployed instance's workspace. |
| `TEST_WORKSPACE_ROOT` | `<repo>/tmp/test_workspace` | Test-env-only workspace root override (for CI). Must resolve to a path inside the checkout — `test_helper.exs` refuses to wipe anything outside it. |
| `MAX_CONCURRENT_RUNS` | `3` | Cap on simultaneously executing task runs; excess stays queued. |
| `LICENSE_KEY` | — | Signed license key for the instance. Optional everywhere including prod — absent means the community tier, which grants everything except container execution (tasks whose Execution is set to Container). Verified offline at boot; anything unusable (bad signature, expired, malformed) logs a warning and falls back to community rather than failing the boot. See [`licensing.md`](licensing.md). |
| `DATABASE_URL` | **required in prod** | `ecto://USER:PASS@HOST/DATABASE`. |
| `SECRET_KEY_BASE` | **required in prod** | Signs and encrypts cookies. `mix phx.gen.secret` or `openssl rand -base64 48`. |
| `PHX_HOST` | `example.com` | The canonical hostname — the one in generated links. Feeds the endpoint's `:url` **and** is always allowed by the origin check (host only, any scheme/port). If the address bar shows a host that is neither this nor in `ALLOWED_HOSTS`, the page renders but LiveView never connects. |
| `ALLOWED_HOSTS` | — | Comma-separated extra addresses the app may be reached at, on top of `PHX_HOST` — so one instance can answer both a LAN IP over http and a domain behind a TLS proxy. A bare host (`192.168.1.50`, `*.example.com`) matches any scheme and port; a full origin (`http://192.168.1.50:4000`) must match exactly; `*` disables the origin check entirely. |
| `SCHEME` | `http` | Scheme for generated absolute URLs (login links, invites, email-change confirmations). Set to `https` when a proxy terminates TLS in front. |
| `PORT` | `4000` | The port the endpoint binds to. Nothing else — it does not appear in generated URLs. |
| `URL_PORT` | `443` when `SCHEME` is `https`, else `80` | The port in generated absolute URLs. Independent of `PORT`, so an instance can listen on 4000 and still emit `https://host` behind a proxy. Set it only when the app is reached directly on a non-standard port (then it equals the *published* port, which need not be `PORT`). |
| `POOL_SIZE` | `10` | Database connection pool size. |
| `ECTO_IPV6` | — | `true`/`1` to add `:inet6` to the database socket options. |
| `DNS_CLUSTER_QUERY` | — | DNS query for node clustering; unused in a single-node deployment. |
| `SMTP_HOST` | — | **The mail switch.** Unset means no transport, and every email surface is hidden (see *Mail* below). Set it to an SMTP relay's hostname to configure `Swoosh.Adapters.SMTP` and turn those surfaces on. |
| `SMTP_PORT` | `587` | Relay port. `465` usually implies `SMTP_SSL=true`. |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | — | Relay credentials. Leave both unset for an unauthenticated relay (auth is only attempted when a username is given). |
| `SMTP_TLS` | `if_available` | STARTTLS policy: `always`, `never`, or `if_available`. The peer certificate is verified against the system CA store whenever TLS is used. |
| `SMTP_SSL` | `false` | `true`/`1` for implicit TLS (the connection is TLS from the start, rather than upgrading via STARTTLS). |
| `MAIL_FROM` | `codelead@$PHX_HOST` | Sender address. Most relays reject a sender they don't recognise, so set this to an address the relay accepts. |
| `MAIL_FROM_NAME` | `CodeLead` | Display name on the sender. |
| `WORKSPACE_VOLUME` | — | Name of the docker volume holding `/data`, **as the host daemon knows it** (`codelead-data` in the shipped stack). When set, sibling task containers mount the workspace by this name. Unset (dev): the workspace root is bind-mounted at the identical path instead. |
| `WORKSPACE_VOLUME_MOUNT` | `/data` | Where the volume (or `HOST_DATA_ROOT` bind) is mounted inside sibling containers. |
| `HOST_DATA_ROOT` | — | Escape hatch (ADR-0003) for stacks whose `/data` is a bind mount rather than a named volume: the *host* path of that directory, passed as the bind source for sibling containers. |
| `CONTAINER_USER` | `1000:1000` in the image, unset in dev | `uid:gid` sibling task containers run as (`docker create --user`), matching the owner of the workspace volume. Unset omits the flag (image default user). |
| `CONTAINER_CPUS` | — | `--cpus` cap per task container (e.g. `2`). |
| `CONTAINER_MEMORY_MB` | — | `--memory` cap per task container, in MB. |
| `HARNESS_VERSION` | `0.66.0`, pinned in `config/runtime.exs` in sync with the image's `CLAUDE_ACP_VERSION` build arg | Version directory the compiled harness binary is staged under (`<WORKSPACE_ROOT>/harness/<version>/`). |
| `HARNESS_SOURCE` | — | Air-gapped escape hatch: a directory of pre-staged harness runtime dirs, one per libc flavor (`<flavor>/` with `claude-agent-acp`, `bun`, `node_modules/`), copied at boot. Normally unset — the harness runtime is staged lazily in-docker on the first container run needing the flavor (ADR-0005/0007). |
| `PREVIEW_PUBLISH_IP` | `127.0.0.1` | Host interface a task container's declared `preview_port` is published on (`docker create -p <ip>:0:<port>`, ephemeral host port). Loopback works when the BEAM runs on the docker host (dev); in the deployed stack set the docker bridge gateway (usually `172.17.0.1`). Never a public interface — browsers only ever reach previews through the authenticated `/preview/:task_id/` proxy (ADR-0008). |
| `PREVIEW_UPSTREAM_HOST` | `127.0.0.1` | Address the in-app preview proxy dials for container-task upstreams (the host port comes from `docker port`). Matches `PREVIEW_PUBLISH_IP` in practice. Local-task previews always dial loopback and need neither variable. |

**Production serves plain HTTP.** `force_ssl` is commented out in
`config/prod.exs` — no redirect, no HSTS — because TLS termination belongs to
whatever proxy the operator already runs. The
`PHX_HOST`/`SCHEME`/`URL_PORT`/`ALLOWED_HOSTS` combinations for direct,
proxied, and simultaneous access are in
[`deployment.md`](deployment.md#urls-phx_host-scheme-url_port-allowed_hosts).

Local dev secrets live in `.envrc` (gitignored, direnv). Deployment secrets go
in a `.env` made from `deployment/.env.example`; `.env` is gitignored, the
template is not.

## Application config keys

- `:workspace_root` — see above.
- `:max_concurrent_runs` — see above.
- `CodeLead.Vault` — Cloak cipher config (set from `ENCRYPTION_KEY`).
- `CodeLead.License` — `key:` only, set from `LICENSE_KEY`. Resolved once in
  `CodeLead.Application.start/2` and cached in `:persistent_term`; nothing
  re-reads it at runtime. There is deliberately no config key for the gated
  feature list or the verification public key — a runtime switch for either
  would be a bypass, which is also why there is no dev-only way to enable
  container execution without a key. See [`licensing.md`](licensing.md).
- `:harnesses` — launch argv per ACP harness, e.g.
  `%{claude_code: ["claude-code-acp"], codex: ["codex", "acp"]}`. See
  *Harness prerequisites* below.
- `:model_prices` — **fallback** pricing per model, in cents per
  million tokens:
  `%{"claude-sonnet-5" => %{input_cents_per_mtok: 300, output_cents_per_mtok: 1500}}`,
  keyed on the agent's `model_variant`. Only consulted when the backend
  reported no money of its own — ACP harnesses normally do, and their
  figure wins. An unlisted model prices at 0, and the table has no cache
  rates, so a derived figure understates cache-heavy runs. Token counts
  are unaffected either way. See
  [`cost-tracking.md`](cost-tracking.md).
- `Oban` — queues: `rollups` (nightly cost rollups) and `dispatch`
  (wake-ups for scheduled runs). Test uses `testing: :manual`; drain
  with `Oban.drain_queue/1` (pass `with_scheduled: true` to fire a
  scheduled run's wake-up early).
- `:git_access_check` — `{module, function}` the first-run wizard calls
  to verify a forge token, default `{CodeLead.Git, :check_access}`. Test
  points it at `CodeLead.GitHelpers` so the suite stays off the network.
- `:docker_cli` — argv prefix for every docker invocation the container
  executor makes, default `["docker"]`. Tests swap it for
  `test/support/fake_docker.sh` the same way `:harnesses` swaps in the
  fake ACP agent. The CLI honours `DOCKER_HOST` as usual.
- `:preview_gateway` — the `CodeLead.PreviewGateway` implementation,
  default `PathProxy`. A test seam first; `SubdomainProxy` later.
- `:preview_publish_ip` / `:preview_upstream_host` — see the env vars
  above.
- `:terminal_shell` — the shell the Terminal tab spawns, default `"sh"`.
- `:terminal_idle_ms` — how long a viewer-less terminal session keeps
  its shell alive, default 15 minutes.
- `:terminal_command` — test-only whole-argv override for local
  terminal spawns (`test/support/fake_shell.sh`), mirroring
  `:docker_cli`.
- `:mail_enabled` / `:mail_from` — see *Mail* below.

## Mail

Email is **opt-in and off by default**. `CodeLead.Mailer.enabled?/0` reads
`:mail_enabled`, which is `false` in `config/config.exs`, `true` in dev and
test, and set to `true` in `config/runtime.exs` only when `SMTP_HOST` is
present. Everything else about mail hangs off that one predicate.

The switch is a dedicated key rather than a look at the configured adapter,
because the adapter cannot answer the question: dev wants mail *on* with
Swoosh's `Local` adapter, and a production build inherits that same adapter
with nothing behind it. Sniffing the adapter is what used to make a deployed
instance advertise a magic-link form and a `/dev/mailbox` link that 404s.

**With mail off**, the surfaces that need a transport are hidden rather than
left to fail silently:

- `/users/log-in` renders only the username/password form — no magic-link
  form, no mailbox notice.
- `/settings/users` offers no "Send a magic-link invite" option and no
  *Resend invite* button.
- `Accounts.deliver_login_instructions/2` and `deliver_invite_instructions/2`
  return `{:error, :mail_disabled}` **before** minting a token, so a crafted
  request can't leave an unusable `users_tokens` row behind. This is the
  authoritative half of the check, mirroring the
  [`licensing.md`](licensing.md) discipline: hiding a control is cosmetic.

Not covered: `/users/settings/email` still accepts an email change and
reports that a confirmation link was sent. With no transport that link never
arrives and the address never changes.

**With mail on**, `SMTP_*` configures `Swoosh.Adapters.SMTP` (via `gen_smtp`)
— the only adapter wired up. To smoke-test a relay without sending real mail,
run a local catcher (`python3 -m aiosmtpd -n -l localhost:1025`) and point
`SMTP_HOST=localhost SMTP_PORT=1025 SMTP_TLS=never` at it.

In development, mail is on with the `Local` adapter and sent mail is
browsable at `/dev/mailbox`. `CodeLead.Mailer.local_mailbox?/0` gates the
links to it on *both* that adapter and the dev routes being compiled in, so
it never points at a route that doesn't exist.

### Preview base path

The live preview serves the task's dev server under
`/preview/<task_id>/`, and the proxy never rewrites response bodies —
an app that emits absolute asset paths must be told its base path.
Terminal sessions export `PREVIEW_BASE_PATH` (e.g. `/preview/42`) and
`PREVIEW_ORIGIN` for exactly this: `vite --base "$PREVIEW_BASE_PATH/"`,
Phoenix `url: [path: System.get_env("PREVIEW_BASE_PATH")]`, Next.js
`basePath`, etc. Framework recipes are iteration-2 material
(`PREVIEW_ROADMAP.md`); the branded 502 page reminds the user meanwhile.

### Serving a preview from a container task

The base path above is what the *browser* needs. A **container** task's
dev server carries further constraints, all consequences of the
execution model rather than settings — a local task has none of them,
because its server runs in the app's own process space and the proxy
dials loopback.

**Bind `0.0.0.0`, not `127.0.0.1`.** The proxy reaches a container task
through a host port published at container create
(`-p <PREVIEW_PUBLISH_IP>:0:<preview_port>`), and a published port cannot
reach a socket bound to the container's own loopback. A server on
`127.0.0.1` is invisible to the preview no matter how the deployment is
configured:

| Stack | Flag |
|---|---|
| Phoenix | `http: [ip: {0, 0, 0, 0}]` |
| Vite | `--host` |
| Next.js | `-H 0.0.0.0` |

**Listen on exactly the declared `preview_port`.** The binding is created
for the port the repository declares, so a server on any other port
resolves to nothing. Declaring or changing `preview_port` after the
container already exists recreates the container on the next terminal or
preview touch — see [Container-task live previews](deployment.md#container-task-live-previews).

**Expect a toolchain, not an environment.** Task containers run with
`--entrypoint sleep`, so the image's own `ENTRYPOINT`/`CMD` never
executes and there is no init system — a database *installed* in the
`image_ref` is never *started*. Nor can you generally start it by hand:
on a **deployed** instance the app image sets `CONTAINER_USER=1000:1000`
itself, so every task container is created `--user 1000:1000` whether or
not the operator asked. That uid usually has no `/etc/passwd` entry in
the task image, which is why `whoami` reports a bare number — you are
not root, `su` prompts for a password that does not exist, and you can
chown nothing. The paths you *do* own are the ones the app created on
the workspace volume: the worktree, the agent home, and the `TMPDIR`
beneath it. (Dev is the opposite case — `CONTAINER_USER` is unset there,
so containers run as the image's default user; see the variable's row
above.)

None of that is accidental. Files written to the shared volume have to
stay owned by the service user, and the [image
contract](adr/0004-container-executor-iteration-two.md) asks for little
more than `sleep`, a shell and git: the container supplies the toolchain
an agent's commands run against, not a running environment.

**So the preview covers a single-process dev server** — one that needs
no companion services. An app that wants a database beside it is waiting
on devcontainer support, which owns the multi-service story
(`PREVIEW_ROADMAP.md`); today the honest answer is to point the app at a
database that already exists somewhere reachable, or to review that work
by diff.

**Background long-running processes.** The terminal session closes its
`docker exec` after 15 minutes with no viewer; the shell sees EOF and
takes its *foreground* children with it. A server started with
`nohup … &` is reparented to the container's PID 1 and keeps serving —
nothing ever stops the container.

What does end it is container *removal*: cancel, Review→Planning
(`worktree_policy: :discard`), reaching Done (finalize always releases
the container), a changed `image_ref`, the stale-binding recreate above,
or the boot reaper for any task not sitting in Review. Only the
workspace mount survives that, so anything written outside it — an
`initdb`'d data dir included — goes with the container. Durable state
belongs under the worktree or the agent home.

## Git credentials

Cloning, fetching and pushing a **private** repository over `https://`
needs a forge access token. It lives in the encrypted project env store
under the key for the repository's forge:

| Forge | Project env key |
|---|---|
| `github.com` | `GITHUB_TOKEN` |
| `gitlab.com` | `GITLAB_TOKEN` |

The same value is used for git transport *and* for opening the PR/MR at
Done — one token, one place. Set it in the first-run wizard's project
step, or on an existing project from the console:

```elixir
CodeLead.Projects.put_env(project_id, "GITHUB_TOKEN", "github_pat_…")
```

The wizard verifies the token against the remote (`git ls-remote`) the
moment you save it, so a bad one is reported there rather than at the
first dispatch.

`CodeLead.Git` hands the token to git through a per-invocation
`credential.helper` that reads it back out of the subprocess
environment, so it never lands in `.git/config`, in argv, or anywhere on
disk. The helper answers with the username `x-access-token`; both forges
ignore it and authenticate on the token alone, so there is no username
to configure. Dispatch failures are scrubbed of anything token-shaped
before they reach `task_steps`.

Three limits worth knowing:

- **SSH remotes (`git@…`) ignore the token** and use the server user's
  own key. The key must be usable without a passphrase prompt — git runs
  with `BatchMode=yes` and will fail rather than block.
- **Only GitHub and GitLab have a token convention.** Self-hosted forges
  fall back to the host's ambient git credentials.
- **With no token stored, git falls back to the server's own
  credentials** — the operator's keychain on a dev laptop, nothing at all
  in a container. This is the one that surprises people: a private repo
  can clone fine for weeks and then start failing the day a token is
  added, because installing the helper also *resets* the inherited ones.
  A local-only success is not evidence the deployment will work.

### When git refuses

`ensure_clone/3` re-points `origin` at the project's current repository
URL on every run, so editing the URL takes effect without deleting the
base clone. What it cannot fix is the credential — at clone time on
dispatch, or at push time when Approve → Done finalizes. `LC_ALL=C` pins
these messages, so they are safe to match on:

| Git says | What it means |
|---|---|
| `Invalid username or token` | The token was presented and rejected — expired, revoked, or simply not the value you think is stored. Note GitHub appends "Password authentication is not supported for Git operations" to *every* HTTPS auth failure; it is boilerplate, not the diagnosis. |
| `Repository not found` | The credential is valid but has no access to that repository — or the owner/repo in the URL is wrong. |
| `Write access to repository not granted` (HTTP 403 on push) | The token is valid and can *read* — clone and dispatch succeed, only Approve → Done fails. It has no write scope. Fine-grained PAT: **Contents: Read and write**. Classic PAT: the `repo` scope. GitLab words this `You are not allowed to push code to this project` and needs `write_repository`. |
| `could not read Username … terminal prompts disabled` | No token stored *and* no ambient credential on the host. |
| `Permission denied (publickey)` | An SSH remote whose key the server cannot use. |
| `CONFLICT (content)` / `Automatic merge failed` | Merge or squash mode only: the branch conflicts with the default branch. Nothing was merged and nothing pushed. Request changes so the agent rebases, or switch the task to Pull request mode and resolve it on the forge. |
| `non-fast-forward` / `Updates were rejected` | Merge or squash mode only: the default branch moved on the remote between the fetch and the push. Nothing landed — approve again to retry against its new tip. Never force-pushed. |
| `protected branch` / `GH006` / `pre-receive hook declined` | The remote refuses direct pushes to the default branch. This is exactly what Pull request mode is for; switch the task or the project default. |

`CodeLead.Git.refusal/1` sorts output into these three classes
(`:auth` / `:write_denied` / `:other`) and `remote_failure/4` turns one
into the sentence the operator reads. The last three rows are not about
credentials, so they get their own pair — `merge_refusal/1` and
`merge_failure/4`, which falls through to `remote_failure/4` for
anything that *is*.

### Approve defaults (per project)

`projects.settings["finalize"]` holds what Approve → Done does by
default, edited under **Settings → Projects → \<project\> → On approve**:

| Key | Values | Applies to |
|---|---|---|
| `repo` | `pull_request` (default) / `merge` / `squash` | `:repo`-target tasks |
| `folder` | `artifact` (default) / `commit_to_path` | `:folder`-target tasks |
| `commit_path` | a repository-relative path, default `artifacts` | where `commit_to_path` lands the artifact |

An individual task overrides this in the **On approve** selector on its
own page (`tasks.finalize_mode`); leaving it on *Project default* means
it keeps following the project, including after the project changes.
An unrecognized or wrong-target value in the column is ignored rather
than run — see [`task-workflow.md`](task-workflow.md) → *Finalize modes*.

Merge and squash push straight to the repository's default branch. On a
forge with branch protection that push will be refused; use pull-request
mode there.

### PR template (per project)

`projects.settings["pr_template"]` holds the description used when
Approve → Done opens a pull/merge request, edited under **Settings →
Projects → \<project\> → PR template**. A blank field clears it back to
the built-in default:

```
{{description}}

---
Created by CodeLead for task #{{task_id}}.
```

`CodeLead.Finalizer.create_pull_request/4` substitutes four
placeholders before sending the body to the forge: `{{title}}`,
`{{description}}`, `{{task_id}}` and `{{branch}}`. The template only
affects the PR/MR **body** — the title is always `tasks.title`
verbatim, and merge/squash mode never opens a PR at all.

Triage a GitHub token without involving CodeLead:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" https://api.github.com/repos/OWNER/REPO
# 200 = valid, with access · 401 = expired or invalid · 404 = valid, no access to that repo
```

A fine-grained PAT needs the repository's owner as its **resource
owner**, that repository selected under *Repository access*, and
**Contents: Read and write** (read alone clones, but Done pushes).

Every git invocation runs with a sanitized environment: `GIT_ASKPASS`,
`SSH_ASKPASS` and the `VSCODE_GIT_ASKPASS_*` variables are unset,
`GIT_TERMINAL_PROMPT=0`, and `LC_ALL=C`. Without this, a server started
from a VS Code integrated terminal inherits that terminal's askpass hook
and a clone pops a GitHub sign-in dialog on the operator's desktop
instead of failing; on a headless host it would hang instead.

## Harness prerequisites

`:acp` agents launch a harness binary that must be on the **`PATH` of
the process running CodeLead** (`System.find_executable/1` resolves it
before the port is opened — putting `PATH` in the project env store does
not help).

| Harness | Binary | Install |
|---|---|---|
| `claude_code` | `claude-agent-acp` | `npm i -g @agentclientprotocol/claude-agent-acp` (needs Node ≥ 22) |
| `codex` | `codex` | the Codex CLI, providing `codex acp` |

A missing binary fails the run at dispatch — before any repository is
cloned — with a message naming the executable.

> The Claude harness was published as `@zed-industries/claude-code-acp`
> (binary `claude-code-acp`) until it was renamed. If you still have the
> old package installed, replace it — the binary name changed, so the
> default `:harnesses` config no longer finds it.

The **Docker image bundles `claude-agent-acp`**; only `codex` is
bring-your-own there. See *Docker image* below.

## Docker image

Published as `ghcr.io/emischorr/codelead:latest` (multi-arch, amd64 and
arm64). `docker build -t codelead .` produces the same release image
locally; it needs no manual harness install. The buildx invocation used to
publish is in the `Dockerfile` header comment, and repeated with the rest of
the deployment story in [`deployment.md`](deployment.md).

| Build arg | Default | Purpose |
|---|---|---|
| `CLAUDE_ACP_VERSION` | pinned in the Dockerfile | Version of `@agentclientprotocol/claude-agent-acp` to bundle. Bump it deliberately — the image is reproducible only because it is pinned. |
| `ALPINE_VERSION` | pinned in the Dockerfile | Base for both the runner and the harness stage. Node comes from that release's `nodejs` package, so the two always agree on musl; the build fails if it is ever older than Node 22, which the harness requires. |

The harness lands in `/opt/harness` (on `PATH`); `npm` stays behind in the
harness stage, so the runner carries only `nodejs`.

**Mount a volume on `/data`.** The image runs as the unprivileged `elixir`
user (uid 1000) and points two variables there:

- `HOME=/data/home` — the agent harness writes its own config and session
  state under `$HOME`. Without a writable home it starts and then fails.
- `WORKSPACE_ROOT=/data/workspace` — base clones, task worktrees, task
  folders. Without the override these would land inside the release
  directory.

### What the agent can run inside the image

An ACP session runs shell commands, so the runner carries a toolbox beyond
what the release itself needs: `bash` (BusyBox has no `bash` applet, and the
harness's shell tool invokes bash — without it *every* shell call the agent
makes fails), the GNU builds of `coreutils`/`findutils`/`grep`/`sed`/
`diffutils` (BusyBox applets share their names but reject flags agents reach
for by habit — `grep -P`, `find -printf`, `sort -V`, `date -d`), plus `curl`,
`jq`, `ripgrep` and `openssh-client`. `SHELL=/bin/bash` is set explicitly
rather than left to a fallback.

**The agent does not see CodeLead's own configuration.** Local subprocesses
(and ACP terminal commands) inherit the app's environment, so
`CodeLead.Executor.EnvScrub` strips the instance-internal variables —
`WORKSPACE_ROOT`, `DATABASE_URL`, `SECRET_KEY_BASE`, `ENCRYPTION_KEY` and
the rest of the names read in `config/runtime.exs` — before spawning.
An inherited `WORKSPACE_ROOT` once let an agent's `mix test` (run inside a
task worktree on CodeLead's own repo) resolve the instance's workspace root
and wipe it. Operator-exported vars outside that denylist still pass
through, and a project env store entry always wins over the scrub, even
under an internal name — a `DATABASE_URL` meant for the *target* app
reaches the agent untouched.

**No language toolchain ships in the image**, and that is the limit worth
knowing before an agent tries to verify its own work. The release bundles ERTS
under `/app`, but neither `mix` nor `elixir` is on `PATH`; `npm` stays behind
in the harness stage (only `nodejs` is copied forward); nothing else — Python,
Go, Rust, a JVM — is there at all. An agent working on an Elixir project
therefore cannot run `mix test` in the stock image, however well the shell
works.

Extend the image with whatever the projects you point CodeLead at need to
build and test themselves:

```dockerfile
FROM ghcr.io/emischorr/codelead:latest
USER root
RUN apk add --no-cache elixir     # or nodejs npm / python3 / go / cargo …
USER elixir
```

Then swap `image:` for a `build:` in
[`deployment/docker-compose.yml`](../deployment/docker-compose.yml), or point
`image:` at your own tag.

Anything `apk` installs lands on `PATH` and needs nothing further. A toolchain
that installs **elsewhere** (`/opt/...`, a version manager under `$HOME`) does
need one more line, because Alpine's `/etc/profile` assigns `PATH` outright
instead of extending it and the harness builds its shell snapshot from a login
shell — so a bare `ENV PATH=` in your layer will not survive into the agent's
commands. Drop a profile snippet next to the image's own:

```dockerfile
RUN printf 'export PATH="/opt/mytool/bin:$PATH"\n' > /etc/profile.d/mytool.sh
```

> A `PATH` entry in the **project env store** replaces the inherited one for
> the harness (`Port.open`'s `env:` merges into the parent environment, so a
> key that is present wins), which hides every tool above. The same caveat as
> *Harness prerequisites*, one layer down: it does not help the agent find its
> tools, it stops it.

Extending the image is the workaround for **local** execution's single
shared environment. The per-repository fix is live: declare a container
image on the repository (Settings → Project → Repositories, or
`repositories.env_kind: :image` + `image_ref`) and switch the task's
Execution to Container — the agent then runs inside that image, with
the project's exact toolchain, over the docker socket
([ADR-0003](adr/0003-container-execution-model.md),
[ADR-0004](adr/0004-container-executor-iteration-two.md)). Container
execution is the one licensed feature — `:container_execution_env` — so
an instance with no `LICENSE_KEY` can declare an image but cannot select
or start Container execution; see [`licensing.md`](licensing.md). There
is deliberately no fallback image: an undeclared environment blocks the
start instead of running somewhere nobody chose. The
`devcontainer_path`/`dockerfile` fields and `agents.tool_features`
remain dormant seams. The declared image must provide `sleep` (the idle
entrypoint) and, practically, a shell and git — beyond that, any musl
(Alpine) or glibc (Debian bookworm or newer) base works: the image's
libc is probed at run start and the matching harness flavor is used
(ADR-0006). The harness ships its own runtime — a staged directory on
the workspace volume holding bun plus the adapter's package tree
(ADR-0007), assembled in-docker on first use — so user images need no
node, nothing harness-related.

Two things the image does *not* get to decide, worth knowing before
building one. Its `ENTRYPOINT`/`CMD` is replaced by the idle `sleep`, so
nothing the image would normally start on boot ever runs; and on a
deployed instance the container is created `--user 1000:1000` regardless
of the image's own `USER`, so execs land on a uid that typically has no
account in the image. Both follow from the container being a toolchain
rather than an environment — see [Serving a preview from a container
task](#serving-a-preview-from-a-container-task) for what that rules out.

### Container execution in dev

Dev needs a `LICENSE_KEY` granting `:container_execution_env` — the gate
applies to a dev instance exactly as it does to a deployed one, and there
is no config override. Mint yourself an `owner` key
(see [`licensing.md`](licensing.md)) and export it from `.envrc`.

The BEAM runs on the host in dev, so sibling containers bind-mount the
workspace at its real path — Docker Desktop's file sharing must cover
it. Nothing else to set up: declare a container image on a repository
(the field in the repository modal — a `container:` badge confirms it),
set a task's Execution to Container, and Start. The **first** container
run per libc family stages the matching harness runtime in a one-shot
bun container (ADR-0005/0007) — a few minutes, logged as `staging
container harness …`, while the task sits dispatched; it needs
docker-side network access to the npm registry, and a failed staging
lands as a `run_failed` attention with the remedy. Every later run
starts instantly, and `docker ps` shows `codelead-task-<id>` while one
runs.
Air-gapped or picky setups can bypass the build by pointing
`HARNESS_SOURCE` at a pre-built binary. `mix test --only docker` runs
the real-daemon integration test.

Migrations are not automatic *inside the image*: `/app/bin/server` is the
default command, and `/app/bin/migrate` (which evals
`CodeLead.Release.migrate/0`) has to be run separately. The compose stack in
[`deployment/`](../deployment/) does that with a one-shot `migrate` service
the app waits on, so a deployed instance migrates itself on every
`docker compose up`.

## Workspace layout (planned)

```
<WORKSPACE_ROOT>/
  repos/<repo-name>/        # managed base clone per linked repository
  worktrees/task-<id>/      # git worktree per :repo-target task
  tasks/<id>/               # task folder per :folder-target task
```
