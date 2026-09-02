---
name: codelead-ready
description: Make this repository work with CodeLead — honor PREVIEW_BASE_PATH/PREVIEW_PORT, bind 0.0.0.0, remove root-absolute URLs that escape the preview mount, and scaffold or audit-and-repair .devcontainer/ so container execution works. Use when asked to make a project CodeLead-ready, when a CodeLead preview 404s, flickers, reloads in a loop, or shows nothing, when adding a devcontainer for CodeLead, or when tasks re-install dependencies on every run.
---

# Make this project CodeLead-ready

CodeLead runs agents on a git worktree of this repository and previews the
dev server in its Review tab. The preview proxy **never rewrites response
bodies**, so the app has to be told where it is being served from. Container
execution runs the task inside the environment this repo's own
`.devcontainer` describes, with no fallback.

This skill makes both work. Do the steps in order; each one is small.

## What CodeLead hands the project

Three environment variables, in the preview command and in every terminal
session — nothing else:

| Variable | Value | Note |
|---|---|---|
| `PREVIEW_PORT` | e.g. `4001` | Declared per repository in CodeLead, unique across the instance. Never detected. |
| `PREVIEW_BASE_PATH` | `/preview/42` or `""` | **No trailing slash.** Empty when the instance gives each task its own origin. |
| `PREVIEW_ORIGIN` | `https://codelead.example.com` | Browser-facing origin. |

Every change you make must be a no-op when these are unset, so ordinary local
development is unaffected.

## 1. Detect the stack

Look for `package.json` (then `vite`/`next`/`nuxt`/`astro` in its deps),
`mix.exs`, `Gemfile` + `config/application.rb`, `pyproject.toml`/`manage.py`,
`go.mod`, `Cargo.toml`. Otherwise treat it as static or generic.

Read **only** the matching section of `references/stacks.md`.

## 2. Bind the port, bind every interface

Make the dev server listen on `PREVIEW_PORT`, falling back to the project's
usual port when unset, and bind `0.0.0.0` rather than `127.0.0.1` — a socket
on the container's own loopback is unreachable from the preview.

Prefer the flag form where the framework has one (Vite, Next.js, Rails,
Django): the flag rides in the **CodeLead-side preview command** and this
repo stays untouched. Edit config only for frameworks that offer no flag
(Phoenix's endpoint, Next.js's `basePath`).

## 3. Honor the base path

Apply the base-path recipe from `references/stacks.md`, always with an
unset-safe default (`"/"` or `""`, per stack).

## 4. Sweep for URLs that escape the mount

Honoring the base path configures the *router*. Anything outside the router
still emits root-absolute URLs and will hit CodeLead instead of this app.
Grep for, and report with `file:line`:

```
new LiveSocket("/        new WebSocket("/        io("/
url("/          url('/          url(/
href="/"        src="/          action="/
fetch("/        fetch('/
```

Fix the mechanical ones — route helpers instead of literals, CSS urls made
relative to where the *bundle* lands (count levels from the built file, not
the source). Flag anything ambiguous rather than guessing.

Discard the false positives before reporting: these patterns also match
documentation, comments, tests, error-page copy and anything under
`node_modules`/`deps`/`_build`. Only URLs the app actually serves count.

The sharpest case is a **hardcoded websocket path**. It connects to
CodeLead's own socket endpoint, which accepts the upgrade and then rejects
the join, and the client falls back to a full page load — so the preview
reloads itself a few times a second, forever. `references/stacks.md` has the
Phoenix fix; the same shape (render the path server-side, read it from a
meta tag) applies to any framework.

## 5. `.devcontainer/` — scaffold if missing, audit **and fix** if present

CodeLead discovers `.devcontainer/devcontainer.json`, `.devcontainer.json`,
or `.devcontainer/<folder>/devcontainer.json`.

**If missing**, generate one from the stack starter in `references/stacks.md`:
a plain `"image"` when the project needs no companion services, a
`"dockerComposeFile"` when it needs a database or cache.

**If present**, four things are non-negotiable, and a devcontainer written for
VS Code almost never has them — they are the reason this step exists. Take the
row for the stack you detected in step 1:

| Stack | Toolchain out of `$HOME` | Off the workspace mount | Lockfile to `COPY` |
|---|---|---|---|
| Phoenix | `MIX_HOME`, `HEX_HOME` | `MIX_BUILD_ROOT`, `MIX_DEPS_PATH` | `mix.lock` |
| Rails | `GEM_HOME`, `BUNDLE_PATH`, `BUNDLE_APP_CONFIG` | — | `Gemfile.lock` |
| Node (Vite/Next) | `NPM_CONFIG_PREFIX`, `PNPM_HOME` | — | `package-lock.json` / `pnpm-lock.yaml` |
| Django | venv at `/opt/venv`, `PIP_CACHE_DIR` | — | `poetry.lock` / `requirements.txt` |
| Rust | `CARGO_HOME`, `RUSTUP_HOME` | `CARGO_TARGET_DIR` | `Cargo.lock` |

Why each, in a sentence:

- **`remoteUser` (or `containerUser`) is set.** Without it agent execs run as
  the image default — usually root — and root-owned files in the worktree block
  teardown later.
- **Toolchain and package-manager state outside `$HOME`.** CodeLead overrides
  `HOME` per task, so anything a feature or image installed under `~` is simply
  not there for an agent. Point it at `/opt/…`.
- **Build output off the shared workspace mount.** The worktree is bind-shared
  with the host, so host-built and Linux-built artifacts poison each other.
- **Dependency install in the image, keyed on the lockfile.** `COPY` the
  manifest + lockfile alone, install in a `RUN` above the source. Every task is
  a fresh container and the host's layer cache is the only thing shared between
  them, so a hook-time install is paid *per task* — in wall-clock, in agent
  tokens, and in a network round-trip that a git-sourced or privately-hosted
  dependency can fail outright.

Run the audit, substituting your row above:

```bash
# .devcontainer audit — from the repo root
grep -rn  '"remoteUser"\|"containerUser"' .devcontainer/ || echo 'GAP: no remoteUser'
grep -rn  '<HOME_VARS>'                   .devcontainer/ || echo 'GAP: toolchain state left in $HOME'
grep -rn  '<MOUNT_VARS>'                  .devcontainer/ || echo 'GAP: build output on the workspace mount'
grep -rEn '^[[:space:]]*COPY.*<LOCKFILE>' .devcontainer/ || echo 'GAP: no lockfile-keyed dep layer'
```

`<HOME_VARS>` and `<MOUNT_VARS>` are your row's names, each with a **trailing
`=`** and joined by `\|` — Phoenix's second line is `'MIX_HOME=\|HEX_HOME='`,
its third `'MIX_BUILD_ROOT=\|MIX_DEPS_PATH='`. The `=` is what separates a real
assignment from a comment that merely mentions the variable, and the anchored
`COPY` is what keeps a comment about copying the lockfile from counting. Where
a row names a path instead of a variable (Django's `/opt/venv`), grep the path;
where the mount column is `—`, skip that line.

**Fix every `GAP:` the audit prints — do not merely report it.** Edit the
existing files: `remoteUser` into `devcontainer.json`; into the `Dockerfile`,
the `ENV` line, its matching `mkdir -p` + `chown`, and the
`COPY <manifest> <lockfile>` + install `RUN` above the source. Take the shape
from your stack's starter in `references/stacks.md`, then cut the lifecycle
hooks back to reconciling the delta. Quote the audit output in your final
report.

Check the rest and **report** the gaps:

- Lifecycle hooks reconcile the *delta*: `postCreateCommand` for the
  lockfile-drift install, seeds and an initial build; `postStartCommand` for
  migrations, because it re-runs on every start while `postCreateCommand` runs
  only on creation. Make `postStartCommand` non-fatal (`… || echo …`) so a bad
  migration cannot lock you out of the Terminal. Neither belongs in the start
  command.
- The project's `CLAUDE.md`/`AGENTS.md` says the environment arrives
  provisioned, so agents don't re-run setup out of habit — step 6 writes it.
- Companion services come from `dockerComposeFile`. CodeLead has no services
  model of its own.
- `PATH` additions are in `/etc/profile.d/*.sh` — the preview command runs
  under a login shell.
- The base is glibc (Debian bookworm or newer) or musl (Alpine), and `sh` is
  present. `script` (util-linux) is worth adding for a full PTY in the
  Terminal tab.
- Resource caps, if any, are `runArgs` / `hostRequirements`.

**Do not add** `forwardPorts`, `appPort`, or `portsAttributes` for CodeLead's
sake — it never reads them, and reachability is handled on its side. Leave
existing ones alone; they serve the VS Code path. Likewise `workspaceFolder`
is honored by the devcontainer CLI but is not where CodeLead execs run, so
never "fix" paths to match it.

## 6. Write the agent instructions

Append the block from `references/agents-snippet.md` to this repo's
`CLAUDE.md` / `AGENTS.md`, creating the file if there is none, with **both**
marked lines substituted — the base-path recipe and the provisioned-environment
line naming where step 5 put deps and build output. If a *CodeLead preview
contract* section is already there, update it in place instead of adding a
second one.

## 7. Verify

**The preview.** Run the server the way CodeLead will, from the repo root:

```bash
PREVIEW_BASE_PATH=/preview/1 PREVIEW_PORT=<port> <preview command>
```

Then, in another shell:

```bash
curl -sSI http://127.0.0.1:<port>/            # must answer, any status
curl -s http://127.0.0.1:<port>/ | grep -oE '(src|href)="/[^"]*"'
```

The second command should print nothing that is not prefixed with
`/preview/1`. An open port is not enough — CodeLead treats a preview as
running only once it gets an **HTTP answer**.

**The devcontainer.** Re-run the audit block from step 5. It must print no
`GAP:` line. A grep hit proves only that the Dockerfile *mentions* the
variable; if the devcontainer CLI and docker are available, prove it reaches an
exec:

```bash
devcontainer up --workspace-folder .
docker exec <container-id> printenv | grep -E '<HOME_VARS>|<BUILD_VARS>'
```

Report what passed and what did not, the devcontainer audit included. Do not
claim success on a step you could not run.

## 8. Tell the owner what to enter in CodeLead

Finish with the settings a human still has to fill in under
**Settings → Projects → <project> → repository**:

- **Preview port** — the port you standardized on. Must be unique across the
  instance and cannot be CodeLead's own port.
- **Preview command** — a **single process**. A leading `VAR=value` prefix is
  fine; `&&`, `|` and `;` do not survive the container path. Give the exact
  string, e.g. `npm run dev -- --host --port "$PREVIEW_PORT" --base "$PREVIEW_BASE_PATH/"`.
- **Container execution** — whether to enable it for this repository, given
  what you found in step 5.

## Out of scope

Say so rather than attempting these:

- **Double-submit CSRF** (Django, Laravel, Angular) breaks on AJAX writes
  when the preview shares CodeLead's origin, because client JS looks for a
  cookie whose name the proxy namespaced. No project change fixes it — the
  operator enabling per-task origins does.
- **`_clp_session`** is a reserved cookie name; if this app uses it, rename.
- Anything on the operator's side (DNS, TLS, reverse proxy, the instance's
  own environment).
