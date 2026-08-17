# Git plumbing & workspace (last updated: 2026-08-15)

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
  of `ecto.drop` so its guard can still query the database) drops
  `worktrees/`, `tasks/`, `surveys/`, `merges/` and `agent-homes/`,
  prunes the base clones, and best-effort removes labeled task
  containers, so a reset stops leaving orphans behind. It refuses to
  run while any task has a live or pending run (`queued`, `dispatched`,
  `executing` in the database) — cleaning would pull worktrees and
  containers out from under running agents; `--force` overrides, and a
  refusal aborts the whole `ecto.reset` before the drop.
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
  deletes the local feature branch.
- `spawn/3` opens an Erlang Port in the context directory with the
  decrypted project env injected — the stdio bridge the ACP driver
  attaches to.

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
`:repo` targets with `execution_env: :container` get `DockerContainer`,
everything else (including every `:folder` target) the configured
default (`impl/0`, `LocalSubprocess`). The resolved module travels on
`Context.executor`, so spawn and teardown always use the executor the
context was built for; hand-built contexts (planning surveys) default
to local. `Executor.available?/1` is the preflight face of the
behaviour — see `docs/agent-drivers.md`.

`DockerContainer` ([ADR-0003](adr/0003-container-execution-model.md),
[ADR-0004](adr/0004-container-executor-iteration-two.md)) delegates all
git/worktree provisioning to `LocalSubprocess` — git stays host-side —
and adds the sibling container: created from the repository's declared
`image_ref` (`env_kind: :image`; no fallback image exists), named
`codelead-task-<id>`, labeled `codelead.*`, idling on `sleep` so any
number of `docker exec -i` bridges can attach. The workspace reaches it
as a named volume (`WORKSPACE_VOLUME`), a `HOST_DATA_ROOT` bind, or —
in dev, where the BEAM runs on the host — a bind of the workspace root
at the identical path; all three keep host and container paths
coincident. Containers are cattle: `spawn` re-ensures the container, so
external removal costs one recreate; the harness `HOME` lives in
`agent-homes/task-<id>` on the volume so sessions survive, and every
exec also gets `TMPDIR=<agent-home>/.tmp` because the task image's
`/tmp` may not be writable for `CONTAINER_USER`.
`Context.exec_ref` (the container name) is not durable —
`StageEffects.discard_context/1` rebuilds a `%Context{}` from DB rows
before teardown, so the executor recovers identity from the task id
alone. `teardown(keep: true)` means "release ephemeral, keep durable":
cancel and Done remove the container while the worktree and agent home
stay; send-back-to-planning removes all three. The repository's
`devcontainer_path`/`dockerfile` fields and `agents.tool_features`
remain dormant seams.

Tests build throwaway `file://` origins via `CodeLead.GitHelpers`
inside the test workspace root — no network, no real harness needed.
