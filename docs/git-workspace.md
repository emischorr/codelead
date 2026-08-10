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
  branch.
- `commit_all/2` commits as `CodeLead <codelead@localhost>`; `:noop`
  when clean. `push/2` pushes the feature branch with upstream.
- `teardown/2`: `keep: true` (cancel/inspection) leaves everything;
  `keep: false` (send-back-to-planning) removes the worktree and
  deletes the local feature branch.
- `spawn/3` opens an Erlang Port in the context directory with the
  decrypted project env injected — the stdio bridge the ACP driver
  attaches to.

Executor selection: `CodeLead.Executor.impl/0` reads `:executor` app
config (defaults to `LocalSubprocess`); `DockerContainer` is the
planned later implementation behind the same behaviour.

Tests build throwaway `file://` origins via `CodeLead.GitHelpers`
inside the test workspace root — no network, no real harness needed.
