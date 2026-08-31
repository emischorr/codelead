# Git plumbing & workspace (last updated: 2026-08-31, background finalization + PR reuse)

Applies to `:repo`-target tasks of any work type; `:folder`-target
tasks use a task folder and skip the branch/push flow.

## Layout (`CodeLead.Workspace`)

```
<WORKSPACE_ROOT>/
  repos/<name>-<repo_id>/   one managed base clone per linked repository
  worktrees/task-<id>/      git worktree per :repo task
  tasks/<id>/               task folder per :folder task
  surveys/task-<id>/        disposable read-only planning survey checkout
  merges/task-<id>/         disposable worktree a Done merge is staged in
  agent-homes/task-<id>/    harness HOME for container runs — session state
                            that must survive container recreation
  harness/<version>/<flavor>/ staged harness runtime per libc flavor (musl/
                            glibc, matched to the task image by probe): a sh
                            wrapper, the bun runtime, and the adapter's
                            package tree — assembled in-docker on the first
                            container run (ADR-0005/0006/0007)
```

## Flow (`CodeLead.Git` + `CodeLead.Executor.LocalSubprocess`)

- `provision/1` (repo target): `ensure_clone` the base clone (fetches
  when it already exists), then a worktree on branch
  `codelead/task-<id>-<slug>` starting from `origin/<default_branch>`.
  Worktree path + branch are persisted on the task
  (`Tasks.set_execution_context/3`) on **every** provisioning, not just
  the first — a run whose context is missing from the task leaves the
  Diff tab, the Terminal tab, the reviewers, and the finalizer with
  nothing to work from. The base clone path is persisted on the
  repository.
- Provisioning is idempotent, but a directory at the expected path is
  **not** on its own grounds for reuse. `Git.worktree_branch/2` asks the
  base clone's own worktree registry whether it owns that path, and
  reuse adopts the branch git reports there. Anything else — a
  directory the clone does not know, one whose registration is stale —
  is removed and reprovisioned. Worktree paths are keyed on the task id
  alone while `mix ecto.reset` reissues ids and leaves the workspace
  volume standing, so `worktrees/task-<id>` may well be a leftover from
  an earlier generation, on an unrelated repository; reusing one
  unchecked runs the agent in the wrong repo and reports nothing. `mix
  code_lead.workspace.clean` (wired into the `ecto.reset` alias, ahead
  of `ecto.drop` so its guard can still query the database) best-effort
  removes labeled task containers *first* — that is the only lever it
  has over processes still writing into the worktrees — then drops
  `worktrees/`, `tasks/`, `surveys/`, `merges/` and `agent-homes/` and
  prunes the base clones, so a reset stops leaving orphans behind. It
  refuses to run for two separate reasons: any task with a live or
  pending run (`queued`, `dispatched`, `executing` in the database),
  since cleaning would pull worktrees and containers out from under
  running agents; and any task sitting in **Review**, where a preview
  server or a Developer shell outlives the run and may still be writing
  into those paths. The task runs without the application started, so
  it cannot ask a live instance to stop those sessions — stopping the
  instance is what ends them (ADR-0013). `--force` overrides either, and
  a refusal aborts the whole `ecto.reset` before the drop.

  What no cold BEAM can reach: a *local* preview server or shell
  orphaned by an ungraceful exit (`kill -9`, OOM). It has no pid file
  and nothing records it; find it with `lsof -i :<preview_port>` and
  reap it by hand.
- A task whose recorded branch survives but whose worktree directory is
  gone is re-attached to that branch (`Git.attach_worktree/3`) rather
  than branched afresh — its commits are still wanted. A branch bearing
  the computed name that *no* task records is an abandoned leftover and
  is deleted before the worktree is created.
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
  when clean. `push/3` pushes the feature branch with upstream;
  `push_ref/4` pushes a ref to a differently-named remote branch
  (`HEAD:main`) and is never forced.
- `teardown/2`: `keep: true` (cancel/inspection) leaves everything;
  `keep: false` (send-back-to-planning) removes the worktree and
  deletes the local feature branch. Removal is **verified** —
  `Git.remove_worktree/2` reports `{:error, {:leftover, path}}` when the
  directory survives instead of pretending — and `git worktree prune`
  runs only on verified removal, because prune is repository-wide and
  running it while a *sibling* worktree is unreachable would drop that
  sibling's registration too. A teardown error never aborts the
  transition that asked for it (already committed); it is logged,
  recorded as a `task_steps` row, and flashed to the user, and the next
  provisioning refuses to build on the leftover
  (`{:workspace_blocked, path}` with a host-side remedy) rather than
  dying on git's bare `already exists`.
- File deletion inside the workspace goes through
  `CodeLead.Workspace.Remover`: `rm_rf`, verify, and on `eacces` —
  root-owned files a container-executed agent left behind; the
  entrypoint chown is deliberately non-recursive — escalate to a
  root-privileged `docker run --rm -v <parent>:<parent>
  <MAINTENANCE_IMAGE> rm -rf <path>` through the already-mounted
  socket. Installs without docker skip the escalation and surface the
  leftover. As the safety invariant for automating a root `rm -rf`, the
  remover refuses any path outside `Workspace.root/0`.
- `spawn/3` opens an Erlang Port in the context directory with the
  decrypted project env injected — the stdio bridge the ACP driver
  attaches to.

## Persisted paths are a cache, not the truth

`repositories.base_clone_path` and `tasks.worktree_path` are absolute
paths keyed on a `WORKSPACE_ROOT` that can move between boots (a
deployment switching volumes). Trusting a stale one is how work gets
lost: the image still carries a `/data` directory, so a row pointing
there makes `ensure_clone` re-clone into the *container's ephemeral
layer*, and everything committed against that clone dies with the next
`docker compose up -d`
([ADR-0012](adr/0012-workspace-path-reconciliation.md)). Two mechanisms
keep that from happening again:

- **Guarded resolvers.** Every consumer reads the base clone through
  `Projects.base_clone_path/1`, and provisioning resolves the worktree
  target the same way: a persisted path outside the current
  `Workspace.root/0` (checked by `Workspace.under_root?/1`) is never
  used — the canonical location is recomputed, an error is logged, and
  the next provisioning re-persists the healed value.
- **Boot reconciliation.** `CodeLead.Workspace.Reconciler` runs as a
  blocking one-shot before Oban and the endpoint: rows pointing outside
  the current root are rewritten to the recomputed location when the
  files actually exist there (a volume migration), and `git worktree
  repair` re-links every surviving worktree to its base clone — the
  gitdir cross-pointers git itself persists are absolute too, and the
  DB cannot see them. Genuinely lost paths are logged loudly and left
  in place (the resolvers make them inert); nothing is ever deleted at
  boot. Skipped in the test env
  (`config :code_lead, reconcile_workspace_at_boot: false`).

## Reading current default-branch source

`ensure_clone/3` only *fetches* an existing clone — never `pull`,
`reset`, or `checkout` — so the base clone's own working tree stays at
whatever commit it was first cloned at while `origin/*` advances. Any
reader that wants *current* source must go through a ref, not through
that checkout:

- `Git.create_detached_worktree/3` adds a worktree at
  `origin/<default_branch>` with **no branch** (`worktree add --detach`).
  The planning survey provisions one under `surveys/task-<id>` and
  removes it with `remove_worktree/2` when the run ends — see
  [`planning.md`](planning.md). It is not the executor's `provision/1`
  path: no branch is created, nothing is committed or pushed, and no
  worktree/branch reference is written to the task.
- The planning assistant's file tree reads
  `ls-tree -r --name-only origin/<default_branch>` for the same reason.

This is also why a read-only agent gets a disposable checkout rather
than the base clone: `read_only: true` denies `fs/write_text_file` but
not `terminal/create`, so a shared clone would be writable in practice.

## Merging on Done

The `:merge` and `:squash` finalize modes land the branch on the
default branch with git alone — no forge merge endpoint, so it works
against any remote:

```
Git.commit_all(worktree) → Git.push(worktree, branch)      # nothing is lost from here on
Git.fetch(base_clone)
Git.create_detached_worktree(base_clone, merges/task-<id>, default_branch)
Git.merge(staging, branch, strategy: :merge | :squash)
Git.head_sha(staging) → Git.push_ref(staging, "HEAD", default_branch)
Git.delete_remote_branch(base_clone, branch)               # best effort
```

Three things about that order are deliberate:

- **Staged in a disposable detached worktree**, for the same reason the
  planning survey is one: the base clone's working tree is frozen and
  shared with every linked worktree. `remove_worktree/2` runs in an
  `after`, so a conflicted merge is discarded wholesale rather than
  unwound with `merge --abort`.
- **The feature branch is pushed first and deleted last.** If the merge
  conflicts or the push is rejected, the work is already safe on the
  remote and the human can retry or switch the task to Pull request
  mode. This is what a forge's "Merge and delete branch" does.
- **The local branch ref is merged**, not `origin/<branch>` — the task's
  worktree is a linked worktree of this clone, so its commits are
  visible here regardless of what the remote accepted.

Nothing is ever force-pushed. Deleting the remote branch is best-effort
and swallowed: the merge has landed by then, so a leftover branch on
the forge is cosmetic, not a reason to fail Done.

## Finalization is background work, and PR creation is idempotent

Since ADR-0016 all of the above runs in a supervised worker, not in
the approving user's LiveView; the task carries
`run_state: :finalizing` for the duration and is frozen against other
edges. Two consequences for the remote:

- **PR reuse.** Before opening a PR/MR the finalizer asks the forge for
  an open one whose head is the task's branch (GitHub
  `GET /pulls?head=<owner>:<branch>&state=open`, GitLab
  `GET /merge_requests?source_branch=<branch>&state=opened`) and reuses
  its URL — the outcome note says "already open — reused", so approving
  a task whose earlier finalization already opened a PR never opens a
  second. A failed lookup degrades to the POST, whose 422 duplicate
  answer still falls back to the compare link.
- **Interrupted finalization.** A restart mid-finalize leaves no
  worker; at boot the task is reset to `review/idle` with a
  `:finalize_interrupted` attention telling the operator to check the
  remote for a pushed branch or an open pull request before approving
  again. It is never retried automatically: the push may or may not
  have landed, and a blind re-run could double-merge — the PR-reuse GET
  above is what makes the *human's* second approve safe. Merge/squash
  have no equivalent dedupe; their protection is the pushed-first
  branch and the readable conflict error.

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

Diagnosis sits here rather than in the callers: `refusal/1` classifies
output as `:auth`, `:write_denied` (a credential that reads fine and is
refused only at push), or `:other`, and `remote_failure/4` renders that
plus the forge and whether a token was presented into one operator-facing
sentence, redacting the detail on the way out. The git failure sites
feed it — `LocalSubprocess.provision/1` via
`TaskRunner.dispatch_error/1`, and `Finalizer.finalize/2` via
`CodeLeadWeb.FlashMessages.finalize_error/1` — so each enriches its error
with `%{output:, forge:, token_present?:}` at the point where those facts
are still in scope.

Merging fails in ways that are not about credentials at all, so it has
its own pair: `merge_refusal/1` classifies output as `:conflict`,
`:non_fast_forward`, `:protected` or `:other`, and `merge_failure/4`
names the remedy — rebase the branch, approve again, or switch the task
to Pull request mode. `:other` delegates straight to `remote_failure/4`,
which already knows what to say about a rejected or read-only token.
The finalizer's merge path adds `base_branch` to the enrichment map,
because every one of those sentences names the branch being written.

`ensure_clone/3` runs `remote set-url origin` before fetching an
existing clone, so changing a project's repository URL retargets the
base clone instead of being silently ignored.

Executor selection: `CodeLead.Executor.for_task/1` resolves per task —
`:repo` targets with `execution_env: :container` get `Devcontainer`,
everything else (including every `:folder` target) the configured
default (`impl/0`, `LocalSubprocess`). The resolved module travels on
`Context.executor`, so spawn and teardown always use the executor the
context was built for; hand-built contexts (planning surveys) default
to local. `Executor.available?/1` is the preflight face of the
behaviour — see `docs/agent-drivers.md`.

`Devcontainer` ([ADR-0003](adr/0003-container-execution-model.md),
[ADR-0009](adr/0009-devcontainer-execution.md)) delegates all
git/worktree provisioning to `LocalSubprocess` — git stays host-side —
and provisions the environment the repository's own `.devcontainer`
configuration describes via `devcontainer up` (`env_kind:
:devcontainer`; no fallback environment exists), identified by
`codelead.task_container`/`codelead.task_id` id-labels so any number of
`docker exec -i` bridges can attach. The workspace rides in as one
extra `--mount`: a bind of the workspace root at the identical path,
which is how the worktree's gitdir and the staged harness resolve
in-container — and the topology `devcontainer up` itself requires,
since the host daemon resolves the repo's own bind sources host-side.
Provisioning refuses under the legacy `WORKSPACE_VOLUME`/
`HOST_DATA_ROOT` modes (`:workspace_not_host_coincident`), where the
daemon would mount phantom paths. Environments are cattle:
`devcontainer up` is idempotent, so `spawn` re-ensures the environment
and external removal costs one re-up; the harness `HOME` lives in
`agent-homes/task-<id>` on the workspace so sessions survive, and every
exec also gets `TMPDIR=<agent-home>/.tmp` because the environment's
`/tmp` may not be writable for the exec user (`--user` follows the
config's `remoteUser`, read from the `devcontainer.metadata` label).
`Context.exec_ref` (the container id) is not durable —
`StageEffects.discard_context/1` rebuilds a `%Context{}` from DB rows
before teardown, so the executor recovers identity from the task id
alone. `teardown(keep: true)` means "release ephemeral, keep durable":
cancel and Done remove the environment (a compose-based one goes down
as a whole project) while the worktree and agent home stay;
send-back-to-planning removes all three. `agents.tool_features`
remains a dormant seam.

Tests build throwaway `file://` origins via `CodeLead.GitHelpers`
inside the test workspace root — no network, no real harness needed.
