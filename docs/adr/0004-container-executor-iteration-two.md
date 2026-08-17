# 0004 — Container executor: no default image, cattle containers, compiled harness

## Status

Accepted (2026-08-15). Superseded in part by ADR-0009 (image
declaration, idle entrypoint, forced user, resource caps).

## Context

ADR-0003 locked the seams; this records the decisions made when the
`DockerContainer` executor was actually built. Scope of that iteration:
`env_kind: :image` only, repo-target tasks only — `:devcontainer`,
`:dockerfile`, `agents.tool_features`, and container execution for
folder targets stay dormant.

Reality forced two adaptations. First, the harness is not a binary:
`@agentclientprotocol/claude-agent-acp` ships as a ~300 MB Node ES-module
tree requiring node ≥ 22, and upstream publishes no prebuilt
executables — only a supported `bun build --compile` standalone mode.
Second, the brief's "hold at dispatch" for a missing image declaration
maps to nothing visible: a scheduler hold leaves the task silently
queued with no attention and is re-looped forever by the queue kick.

## Decision

- **No default or fallback toolchain image, ever.** A generic image
  cannot match the stack and versions a project needs; an agent
  verifying its work in an environment nobody chose produces
  plausible-but-wrong results. A container task whose repository
  declares no image is refused, visibly.
- **Visible refusal, not a hold.** The start guard
  (`Tasks.startable/2` / stage entry) blocks the move with
  `:missing_execution_env` before the card leaves Planning; if a run
  still reaches dispatch undeclared, provisioning fails into the
  ordinary `run_failed` attention with routing copy. The closed
  attention-type enum is untouched — the detail text carries the
  routing.
- **Containers are cattle.** Durable state lives on the workspace
  volume: the worktree/branch and a per-task agent home
  (`agent-homes/task-<id>`, the harness `HOME`, so sessions survive
  container recreation). Identity is the deterministic name and
  `codelead.*` labels, recovered from the task id alone; `spawn`
  re-ensures the container, so external removal at any moment costs one
  recreate. A boot reaper removes labeled orphans.
- **The staged harness is a bun-compiled, musl-static binary** built in
  the image per arch and copied to the volume at boot
  (`harness/<version>/`) — refining ADR-0003's "mounted binaries" with
  how such a binary exists at all. Static-musl runs on both musl and
  glibc images, so project images owe us nothing. Rejected for now:
  staging the npm tree and requiring node ≥ 22 in every project image.
  Container execution currently supports the Claude Code harness only;
  codex stays local/bring-your-own.
- **Env is injected at `docker exec -e` time**, never at container
  creation: the merge (project env + provider credentials) happens in
  the driver just before spawn, stays fresh across recreation, and
  never lands in the container's config or on disk. The trade — values
  visible in the short-lived CLI process's argv and the exec instance's
  inspect output — is accepted under ADR-0003's single-tenant,
  socket-is-root threat model.
- **One docker transport: the CLI** (`docker-cli` in the image,
  argv behind the `:docker_cli` config so tests fake it like
  `:harnesses`). The `docker exec -i` Port bridge needs the CLI binary
  regardless, so lifecycle commands use it too rather than adding a
  second, API-shaped path.
- **The idle entrypoint is `sleep 2147483647`** (BusyBox has no `sleep
  infinity`), so any number of execs — agent, reviewers, a future
  Developer terminal — attach to one container. The image contract: it
  must provide `sleep`, and practically a shell and git.
- **Sibling containers run as `CONTAINER_USER`** (`uid:gid`, `1000:1000`
  in the image, unset in dev), matching the volume owner; every exec
  additionally carries a `GIT_CONFIG_*` `safe.directory=*` override so
  imperfect uid mapping degrades to nothing rather than to git's
  "dubious ownership" refusal.

## Consequences

- The shipped compose stack now mounts `/var/run/docker.sock` and pins
  the data volume's name (`codelead-data`) so `WORKSPACE_VOLUME` can
  reference it; stacks created before the pin hold the data under
  `deployment_codelead-data` and must say so or migrate.
- Reviewers of a container task exec into the same task container;
  planning surveys always run locally (their disposable worktree has no
  container and never should).
- `teardown(keep: true)` now means "release ephemeral resources, keep
  durable state" — a no-op locally, container-removal for
  `DockerContainer` — and cancel and Done route through it, so no
  container outlives its task's activity.
- Secrets in exec argv are visible to anyone who can read host process
  lists — the same principals the mounted socket already makes
  root-equivalent.
- `bun build --compile` compatibility is guarded only by the build-time
  existence check and the integration smoke test; an SDK change that
  breaks compiled mode surfaces there, and the rejected npm-tree
  fallback is the escape hatch.
