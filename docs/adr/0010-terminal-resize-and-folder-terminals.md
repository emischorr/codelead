# 0010 — Terminal window resize via the PTY device; terminals for folder-target tasks

## Status

Accepted (2026-08-18). Supersedes ADR-0008's "post-spawn resize is out
of scope" and its worktree-only terminal scope.

## Context

ADR-0008 shipped the terminal with two gaps it named and accepted.

**Resize.** The PTY is allocated *inside* the spawned context by
`script(1)`, because Erlang ports have no TTY to hand a subprocess. The
spawning side therefore has no file descriptor on the PTY and cannot
issue `TIOCSWINSZ`, so the shell kept whatever size it started with:
`COLUMNS`/`LINES` were exported but nothing applied them to the device,
and resizing the browser refit xterm.js on the client while the shell
went on believing in 80×24. Line wrapping broke and full-screen programs
(`vim`, `htop`) rendered into the wrong box.

**Folder targets.** `Terminal.ensure_session/2` gated on
`tasks.worktree_path`, which only the `:repo` provisioning path ever
persists. A `folder`-target task has a real, provisioned execution
context — `Workspace.task_folder/1` — but no terminal into it.

## Decision

- **Resize out of band, through the PTY's device node.** The size can
  only be set by a process holding the device, so the session records
  which device it got: the PTY forms no longer exec the shell directly
  but a payload (`Terminal.Command.payload/1`) that writes `tty` output
  to `$CODELEAD_TTY_FILE`, applies the initial `COLUMNS`/`LINES`, then
  `exec`s the shell. A resize runs `stty` against that recorded device
  from *outside* the session — `System.cmd` on the host for local tasks,
  `docker exec` for container ones — and the kernel raises `SIGWINCH` on
  the foreground process group for free. The device file is therefore
  part of the spawn contract, and lives where the context can write:
  the host temp dir locally, the per-task `TMPDIR` in a container.
- **Every step of that payload is best-effort and silenced.** A context
  without `tty`, without `stty`, or without a writable device file still
  gets a working shell — just no live resize. Same posture as the
  existing plain-pipe fallback, which has no PTY to resize at all.
- **Try both `stty` device flags.** util-linux spells it `-F` and BSD
  `-f`, and POSIX standardizes neither. Which one answers depends on the
  binary on PATH rather than the OS — a macOS host with GNU coreutils
  installed wants `-F` — so the resize script tries `-F` and falls back
  to `-f`. Branching on `:os.type()` was tried first and is wrong.
- **Injecting `stty` into the shell's stdin was rejected.** It is the
  usual workaround for terminals without a PTY channel, but it echoes at
  the prompt, corrupts whatever the user was typing, pollutes shell
  history, and does nothing while a foreground program is running.
- **The terminal's context is derived, not persisted.**
  `Terminal.context_path/1` returns the worktree for repo targets and
  `Workspace.task_folder/1` for folder targets, gated on the directory
  existing. Widening `tasks.worktree_path` to mean "execution context"
  was rejected: `Finalizer`, `Reviews`, and `Runtime.StageEffects` all
  read that field as *the worktree*, and the folder path is already
  deterministic from the task id.

## Consequences

- Resizing the browser now resizes the shell, and the *initial* size
  reaches the PTY for the first time — `COLUMNS`/`LINES` alone never did.
- Every PTY session pays one extra `mkdir`/`tty`/`stty` at startup and
  one short-lived process per resize (a `docker exec` for container
  tasks), which is why the client debounces and the session runs the
  resize detached rather than blocking its output stream.
- An image without `stty` silently gets no resize. There is no UI
  signal for it, unlike the plain-pipe fallback's status line.
- Folder-target tasks get a terminal, but still no preview: the preview
  port is declared on the repository, and a folder task has nowhere to
  declare one (see `ROADMAP.md`).
