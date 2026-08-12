# Configuration (last updated: 2026-08-10)

All environment variables are read in `config/runtime.exs` and accessed in
application code via `Application.get_env(:code_lead, ...)` — never
`System.get_env/1` outside of config files (see CODING_GUIDE.md).

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ENCRYPTION_KEY` | fixed dev/test key; **required in prod** | Base64-encoded 32-byte key for `CodeLead.Vault` (Cloak AES-GCM). Encrypts provider credentials and the project env store. Generate: `32 \|> :crypto.strong_rand_bytes() \|> Base.encode64()` |
| `WORKSPACE_ROOT` | `<repo>/workspace` (dev/prod), `<repo>/tmp/test_workspace` (test) | Root for CodeLead-managed working state: base clones, per-task git worktrees, task folders. Gitignored. |
| `MAX_CONCURRENT_RUNS` | `2` | Cap on simultaneously executing task runs; excess stays queued. |
| `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, … | — | Standard Phoenix/Ecto prod settings (see `config/runtime.exs`). |

Local dev secrets live in `.envrc` (gitignored, direnv).

## Application config keys

- `:workspace_root` — see above.
- `:max_concurrent_runs` — see above.
- `CodeLead.Vault` — Cloak cipher config (set from `ENCRYPTION_KEY`).
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
base clone. What it cannot fix is the credential. `LC_ALL=C` pins these
messages, so they are safe to match on:

| Git says | What it means |
|---|---|
| `Invalid username or token` | The token was presented and rejected — expired, revoked, or simply not the value you think is stored. Note GitHub appends "Password authentication is not supported for Git operations" to *every* HTTPS auth failure; it is boilerplate, not the diagnosis. |
| `Repository not found` | The credential is valid but has no access to that repository — or the owner/repo in the URL is wrong. |
| `could not read Username … terminal prompts disabled` | No token stored *and* no ambient credential on the host. |
| `Permission denied (publickey)` | An SSH remote whose key the server cannot use. |

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

`docker build -t code_lead .` produces a release image that needs no
manual harness install.

| Build arg | Default | Purpose |
|---|---|---|
| `CLAUDE_ACP_VERSION` | pinned in the Dockerfile | Version of `@agentclientprotocol/claude-agent-acp` to bundle. Bump it deliberately — the image is reproducible only because it is pinned. |
| `NODE_IMAGE` | `docker.io/node:22-trixie-slim` | Where Node comes from. Keep the Debian release matching `DEBIAN_VERSION`: the runner copies the Node binary, so glibc/libstdc++ must match. |

The harness lands in `/opt/harness` (on `PATH`); Node itself is copied to
`/usr/local/bin/node`.

**Mount a volume on `/data`.** The image runs as `nobody` and points two
variables there:

- `HOME=/data/home` — the agent harness writes its own config and session
  state under `$HOME`. Without a writable home it starts and then fails.
- `WORKSPACE_ROOT=/data/workspace` — base clones, task worktrees, task
  folders. Without the override these would land inside the release
  directory.

Migrations are not automatic: run `/app/bin/migrate` (which evals
`CodeLead.Release.migrate/0`) before or alongside the first boot.
`/app/bin/server` is the default command.

## Workspace layout (planned)

```
<WORKSPACE_ROOT>/
  repos/<repo-name>/        # managed base clone per linked repository
  worktrees/task-<id>/      # git worktree per :repo-target task
  tasks/<id>/               # task folder per :folder-target task
```
