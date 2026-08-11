# Git plumbing & workspace (last updated: 2026-08-10)

Applies to `:repo`-target tasks of any work type; `:folder`-target
tasks use a task folder and skip the branch/push flow.

## Layout (`CodeLead.Workspace`)

```
<WORKSPACE_ROOT>/
  repos/<name>-<repo_id>/   one managed base clone per linked repository
  worktrees/task-<id>/      git worktree per :repo task
  tasks/<id>/               task folder per :folder task
```

## Flow (`CodeLead.Git` + `CodeLead.Executor.LocalSubprocess`)

- `provision/1` (repo target): `ensure_clone` the base clone (fetches
  when it already exists), then a worktree on branch
  `codelead/task-<id>-<slug>` starting from `origin/<default_branch>`.
  Worktree path + branch are persisted on the task
  (`Tasks.set_execution_context/3`); the base clone path on the
  repository. Provisioning is idempotent — multi-run reuses the
  existing worktree.
- `diff/2` computes the full delta (committed + uncommitted; untracked
  visible via `git add -N`) against the merge-base with the default
  branch. The intent-to-add pass runs against a throwaway index seeded
  from the worktree's own (`GIT_INDEX_FILE`, so git locks
  `<scratch>.lock` instead of `index.lock`) — the Diff tab polls this
  every ~1.5s during a run, and staging into the real index would fight
  the agent for the lock and could fail its commit. Seeding from a copy
  rather than `read-tree HEAD` keeps the stat cache, so a refresh
  re-hashes only what changed. Callers pass extra environment through
  `git/3`'s `:env` option.
- `commit_all/2` commits as `CodeLead <codelead@localhost>`; `:noop`
  when clean. `push/3` pushes the feature branch with upstream.
- `teardown/2`: `keep: true` (cancel/inspection) leaves everything;
  `keep: false` (send-back-to-planning) removes the worktree and
  deletes the local feature branch.
- `spawn/3` opens an Erlang Port in the context directory with the
  decrypted project env injected — the stdio bridge the ACP driver
  attaches to.

## Credentials

Functions that touch a remote (`ensure_clone/3`, `push/3`,
`remote_branches/2`, `git/3`) take a `:token` option. The **caller**
resolves it — `Git.forge(git_url)` classifies the remote and
`Projects.forge_token/2` reads `GITHUB_TOKEN`/`GITLAB_TOKEN` out of the
encrypted project env store — so `Git` never reaches into the domain.
Both `LocalSubprocess.provision/1` and `CodeLead.Finalizer` do this.

`Git` installs the token as a per-invocation `credential.helper` (via
`-c`) that echoes it back from the subprocess environment as
`x-access-token` / the token: nothing is written to `.git/config` and
nothing appears in argv. Without a token no helper is installed at all,
which leaves the host's inherited helpers in play — so the presence of a
token changes *which* credentials git uses, not merely whether it has
any. Every invocation, token or not, runs with the launching terminal's
askpass hooks unset, `GIT_TERMINAL_PROMPT=0`, `ssh -o BatchMode=yes`,
and `LC_ALL=C` so git fails fast and in English. See
`docs/configuration.md` → *Git credentials* for the operator-facing
version, including how to read the refusals.

`check_access/2` probes a URL with `ls-remote` and no clone — the
first-run wizard calls it when a token is saved. `failure_reason/1`
picks the line of git output that carries the reason and `redact/1`
scrubs token-shaped substrings; `TaskRunner` uses both before writing a
`task_steps` row.

`ensure_clone/3` runs `remote set-url origin` before fetching an
existing clone, so changing a project's repository URL retargets the
base clone instead of being silently ignored.

Executor selection: `CodeLead.Executor.impl/0` reads `:executor` app
config (defaults to `LocalSubprocess`); `DockerContainer` is the
planned later implementation behind the same behaviour.
`Executor.available?/1` is the preflight face of the behaviour — see
`docs/agent-drivers.md`.

Tests build throwaway `file://` origins via `CodeLead.GitHelpers`
inside the test workspace root — no network, no real harness needed.
