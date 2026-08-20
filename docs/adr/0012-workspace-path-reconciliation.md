# 0012 — Workspace paths as a validated cache; boot reconciliation; verified teardown

## Status

Accepted (2026-08-20).

## Context

The workspace layout is addressed twice: computed from `WORKSPACE_ROOT`
by `CodeLead.Workspace`, and persisted as absolute paths in
`repositories.base_clone_path` and `tasks.worktree_path` — with git
itself persisting a third copy, the absolute gitdir cross-pointers
between a base clone and its worktrees. Until now the persisted DB path
always won (`repository.base_clone_path || Workspace.base_clone_path/2`),
and nothing ever validated any of the three against the current root.

The deployment switch from the `codelead-data:/data` named volume to the
`${DATA_ROOT}` bind mount (ADR-0009) turned that into data loss on a
real instance. The image still ships a `/data` directory, so a stale row
pointing there made `ensure_clone` silently re-clone into the app
container's **ephemeral writable layer**; worktrees were created on the
bind mount with gitdir pointers into `/data`; the next
`docker compose up -d` recreated the container, and the base clone —
holding every git object the Review tasks' commits lived in — vanished.
Symptom: `fatal: not a git repository: /data/…/.git/worktrees/task-N`
on every Review diff.

The same incident exposed that teardown cannot fail visibly:
`Git.remove_worktree/2` discarded all its step results and was typed
`:: :ok`, so send-back-to-planning nulled the task's references while
root-owned files (written by the devcontainer-executed agent; the
entrypoint chown is deliberately non-recursive) survived on disk — and
re-dispatch died on git's bare `fatal: '…' already exists`.

## Decision

1. **Persisted workspace paths are a cache, never trusted outside the
   current root.** Every consumer resolves the base clone through
   `Projects.base_clone_path/1` and the worktree target through the
   executor's guarded resolver; a path failing
   `Workspace.under_root?/1` is replaced by the recomputed canonical
   location, loudly. This kills the ephemeral-layer re-clone
   permanently, independent of any migration tooling.

2. **A blocking one-shot boot step reconciles moved roots.**
   `CodeLead.Workspace.Reconciler` runs after the Repo/Vault and before
   Oban (whose `dispatch` queue can fire immediately), rewriting rows
   that point outside the current root to the recomputed location —
   only where the files actually exist — and running
   `git worktree repair` per base clone to heal the gitdir pointers the
   DB cannot see. Genuinely lost paths are logged and left in place
   (rule 1 makes them inert); the step never deletes anything, rescues
   every failure to a log line, and is skipped in the test env. The
   step has no timeout (local git only) — accepted for now.

3. **Teardown failures surface; transitions still commit.**
   `Git.remove_worktree/2` verifies the directory is gone (reporting
   `{:error, {:leftover, path}}`), prunes only on verified removal —
   an unconditional repo-wide prune while a sibling worktree is
   unreachable would drop the sibling's registration — and the error
   propagates through the executor behaviour
   (`teardown :: :ok | {:error, term()}`), `discard_context`, and
   `Runtime.advance/3` to the UI as a flash plus a `task_steps` row.
   The human's transition stands: the discard runs after the DB write
   by design, and re-provisioning verifies the path is free, failing
   with an actionable `{:workspace_blocked, path}` instead of git's
   `already exists`.

4. **Root-owned leftovers are deleted as root through docker.**
   `CodeLead.Workspace.Remover` escalates an `eacces`-blocked `rm_rf`
   to `docker run --rm -v <parent>:<parent> $MAINTENANCE_IMAGE rm -rf`
   over the already-mounted socket (the same privilege that created the
   files), and refuses any path outside `Workspace.root/0` as the
   safety invariant for automating that. Installs without docker skip
   the escalation and surface the leftover.

## Consequences

- A `WORKSPACE_ROOT` move is now a supported operation: move the data,
  boot, and the instance heals its own references — only clones that
  never lived on durable storage stay lost (recovery documented in
  `docs/deployment.md`).
- The executor `teardown/2` contract changed from `:: :ok` to
  `:: :ok | {:error, term()}`; callers must proceed-and-surface, never
  abort on it.
- `git worktree prune` no longer runs after a failed removal; a truly
  orphaned registration is cleared by the next successful
  `remove_worktree` of that path or by `mix code_lead.workspace.clean`.
  If a stale sibling registration ever needs targeted removal, deleting
  only `.git/worktrees/<name>` is the escalation — deliberately not
  built now.
- Multi-node deployments would race the boot reconciliation; out of
  scope, single-node is the supported topology.
