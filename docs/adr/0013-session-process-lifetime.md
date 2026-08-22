# 0013 — Session process lifetime: signalled shutdown, process-group stop, boot adoption

## Status

Accepted (2026-08-22). Supersedes ADR-0008's assumption that closing a
session's Port ends the process behind it.

## Context

`CodeLead.Terminal` and `CodeLead.Preview` each own a long-lived OS
process per task through an Erlang Port, and both were written as if
`Port.close/1` were a stop mechanism. It is not. Closing a port closes
its pipes; the child survives the close, and survives the VM exiting,
reparenting to init. This is why `MuonTrap` and `erlexec` exist.

The terminal appeared to work anyway, for reasons that do not generalise:
an interactive `sh` exits on stdin EOF, and `script(1)`'s PTY teardown
raises SIGHUP on the foreground process group. A preview's
`sh -lc "npm run dev"` never reads stdin and never sees either signal, so
it simply kept running — holding the preview port against the next start.

Two further facts decided the shape of the fix. Port children are
process-group leaders: `erl_child_setup` calls `setpgid` per child, so
everything a spawned shell starts inherits its pgid and one signal to the
group reaches the whole tree. And a `docker exec` client's death reaches
nothing inside the container, so a container session's process can only
be signalled by a pid the command records for itself.

The two subsystems had diverged in maturity rather than in kind. Preview
had a `stopper` closure, called on exactly three paths; Terminal had
none at all, and no lifecycle call site — no transition, cancel or
finalize ever stopped a shell, so a dev server started from one kept
writing into a worktree while teardown deleted it, which is what turns a
teardown into the leftover ADR-0012 made loud.

## Decision

- **A session that ends, ends its server.** Both `Session` GenServers
  trap exits and carry `shutdown: 10_000`, so `terminate/2` runs on every
  path out — an application shutdown included — and runs the stopper
  before closing the port. The stopper is idempotent by clearing itself,
  which is what makes it safe to call unconditionally from paths that
  already signalled.
- **Stop by process group, not by pid.** The local stoppers signal
  `-pgid`, reaching whatever the command started. Rejected wrapping the
  local command in `exec` the way the container path does: `preview_command`
  is free-form repository config, and `sh -lc "exec npm install && npm run dev"`
  would exec the install and never start the server — breaking a legitimate
  command at *start* time to fix a *stop*-time bug. Rejected `setsid`: the
  group already exists, the code merely omitted the sign.
- **Container sessions record their own pid.** Both the terminal payloads
  and the preview wrapper write `$$` before `exec`, and the stopper signals
  that group through `docker exec`, group-first then bare-pid — busybox
  `kill` may reject a negative pid and `runc exec` does not always create a
  new group. The pipe-fallback payload records it too, or a container
  terminal in an image without `script(1)` would be unstoppable.
- **The terminal stops only when its execution context is destroyed** —
  `discard_context`/`release_context`, never on entering a run. The
  request-changes edge preserves worktree, branch and ACP session by
  design; killing the developer's shell there would destroy held work for
  no correctness gain. Preview's reason for stopping on that edge does not
  transfer: the preview *is* the reviewed artifact and would serve a build
  the run is rewriting, while a terminal is a tool.
- **Surviving container previews are adopted, not duplicated.** The boot
  reaper deliberately spares `review + container` environments so a live
  preview outlives a restart. A boot task now re-attaches a session to any
  such server whose recorded pid is still alive — verified, never trusted,
  since the pid file is never deleted and is stale by construction. An
  adopted session owns no Port (`port: nil`) and reuses the whole ordinary
  lifecycle; if the probe never answers, its start timeout signals the pid
  and forgets it. Rejected killing survivors at boot, which would throw
  away a working server and contradict why the reaper spares them.
- **No shared session abstraction.** The duplicated viewer/idle
  bookkeeping is pure, stable, and produced none of these defects, while
  the two state machines genuinely differ — only Preview probes for
  readiness, only Terminal has bidirectional IO and a resizer. What is
  shared is the OS-signalling knowledge, and that became one pure module,
  `CodeLead.OsProcess`, sibling to `CodeLead.Terminal.Command`.
- **`DockerCli.run/2` takes a `:timeout`**, defaulting to `:infinity` so
  every existing call site is unchanged. Stoppers pass a finite one,
  because an unbounded `System.cmd` under a shutdown budget makes the
  budget meaningless. It bounds the wait, not the CLI child.

## Consequences

- Previews and terminals no longer survive a graceful restart: the
  shutdown that used to leak them now stops them. Adoption therefore
  covers only ungraceful exits — `kill -9`, OOM, a host crash. Making
  previews survive graceful restarts too is a small delta, deliberately
  not taken: it would put a special case in the most safety-critical
  callback and weaken the single rule above.
- A local preview or shell orphaned by an ungraceful exit has no pid file
  and cannot be reaped by anything. `mix code_lead.workspace.clean` runs
  without the application started, so it cannot ask a live instance to
  stop its sessions either; it now refuses while any task sits in Review
  and points the operator at stopping the instance, which is what ends
  those processes. `--force` remains the override.
- Shutdown is bounded at 10 s per session and 5 s per container stopper.
  Sessions are signalled in parallel, so the cost is one stopper, not N.
- Stoppers must stay closures over strings. Reverse-order shutdown stops
  the session supervisors while the Repo is still up, but that ordering is
  not a guarantee worth depending on, and no stopper reads the database.
