---
name: codelead-ready
description: Make this repository work with CodeLead — honor PREVIEW_BASE_PATH/PREVIEW_PORT, bind 0.0.0.0, remove root-absolute URLs that escape the preview mount, and scaffold or audit .devcontainer/ so container execution works. Use when asked to make a project CodeLead-ready, when a CodeLead preview 404s, flickers, reloads in a loop, or shows nothing, or when adding a devcontainer for CodeLead.
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

## 5. `.devcontainer/` — scaffold if missing, audit if present

CodeLead discovers `.devcontainer/devcontainer.json`, `.devcontainer.json`,
or `.devcontainer/<folder>/devcontainer.json`.

**If missing**, generate one from the stack starter in `references/stacks.md`:
a plain `"image"` when the project needs no companion services, a
`"dockerComposeFile"` when it needs a database or cache.

**If present**, check it against this list and report the gaps:

- `remoteUser` (or `containerUser`) is set. Without it agent execs run as the
  image default — usually root — and root-owned files in the worktree block
  teardown later.
- Toolchain and package-manager state lives **outside `$HOME`**
  (`MIX_HOME`/`HEX_HOME`, `CARGO_HOME`/`RUSTUP_HOME`, npm prefix, pyenv root,
  nvm dir → `/opt/…`). CodeLead overrides `HOME` per task, so anything under
  `~` silently vanishes for agents. **This is the gap that bites most often.**
- Build output is **off the shared workspace mount** (`MIX_BUILD_ROOT`,
  cargo `target-dir`, …) — the worktree is bind-shared with the host, so
  host-built and Linux-built artifacts poison each other.
- Dependency installs are **in the image, keyed on the lockfile** — `COPY` the
  manifest + lockfile alone, install in a `RUN` above the source. Every task is
  a fresh container, and the host's layer cache is the only thing shared
  between them; an install left to a hook is paid per task, in wall-clock and
  in agent tokens. **This is the gap that costs most.**
- Lifecycle hooks reconcile the *delta*: `postCreateCommand` for the
  lockfile-drift install, seeds and an initial build; `postStartCommand` for
  migrations, because it re-runs on every start while `postCreateCommand` runs
  only on creation. Make `postStartCommand` non-fatal (`… || echo …`) so a bad
  migration cannot lock you out of the Terminal. Neither belongs in the start
  command.
- The project's `CLAUDE.md`/`AGENTS.md` says the environment arrives
  provisioned, so agents don't re-run setup out of habit.
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
`CLAUDE.md` / `AGENTS.md`, creating the file if there is none, with the stack
line already substituted. If a *CodeLead preview contract* section is already
there, update it in place instead of adding a second one.

## 7. Verify

Run the server the way CodeLead will, from the repo root:

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

Report what passed and what did not. Do not claim success on a step you
could not run.

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
